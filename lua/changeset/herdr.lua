---Hands text to an AI agent in another pane of the same herdr workspace.
local comment_store = require("changeset.comment_store")
local dialog = require("changeset.dialog")
local git = require("changeset.git")
local render = require("changeset.render")

local M = {}

---@class changeset.HerdrAgent
---@field agent string?
---@field agent_status string?
---@field pane_id string
---@field workspace_id string?
---@field name string?
---@field display_agent string?
---@field title string?
---@field state_labels table<string, string>?
---@field cwd string?
---@field foreground_cwd string? The directory of the program in the pane's foreground, the agent; `cwd` is the pane's.
---@field tokens { branch: string? }?

---@class changeset.HerdrSendOpts
---@field title string The agent picker's title, which says what goes.
---@field root string The repository the text is about, whose agents the picker lists first.

---@class changeset.HerdrLast The agent a repository's text last went to.
---@field pane string
---@field dir string? Where it worked then.

---@class changeset.HerdrPlace What ranks the agents in the picker.
---@field worktrees string[] Where the repository is checked out, its own root included.
---@field last changeset.HerdrLast?

local TIMEOUT = 5000
local START, STOP = "\27[200~", "\27[201~"
-- The status of an agent at a permission prompt, which silently drops a paste; any other queues it in the input.
local BLOCKED = "blocked"
local STATUS = "●"
-- Each status's colour in the picker; any other, such as unknown, takes the meta colour.
local STATUS_HL =
  { idle = "DiagnosticOk", done = "DiagnosticOk", working = "DiagnosticWarn", blocked = "DiagnosticError" }
-- Each status's place within a group of the picker's rows: ready first, blocked last, any other before blocked.
local STATUS_RANK = { idle = 1, done = 1, working = 2, blocked = 4 }
local OTHER_RANK = 3

---The agent each repository's text last went to in this Neovim, by root, then branch ("" for none).
---@type table<string, table<string, changeset.HerdrLast>>
local last_agent = {}

---`value` when it is a non-empty string, else nil: herdr writes null, "" or nothing for absent.
---@param value any
---@return string?
local function present(value)
  return type(value) == "string" and value ~= "" and value or nil
end

---The agents in `workspace` other than `own_pane`, in herdr's order.
---@param agents changeset.HerdrAgent[]
---@param workspace string
---@param own_pane string?
---@return changeset.HerdrAgent[]
function M._candidates(agents, workspace, own_pane)
  return vim.tbl_filter(function(a)
    return present(a.agent) ~= nil and a.workspace_id == workspace and a.pane_id ~= own_pane
  end, agents)
end

---What to call `agent` in a picker row or a message.
---@param agent changeset.HerdrAgent
---@return string
function M._name(agent)
  return present(agent.name) or present(agent.display_agent) or present(agent.agent) or agent.pane_id
end

---Where `agent` works: the agent's own directory, else its pane's.
---@param agent changeset.HerdrAgent
---@return string?
local function dir(agent)
  return present(agent.foreground_cwd) or present(agent.cwd)
end

---@param agent changeset.HerdrAgent
---@return string?
local function agent_branch(agent)
  return type(agent.tokens) == "table" and present(agent.tokens.branch) or nil
end

---`agents` in the picker's order: the one `place.last` names while it works where it did, then those working in the
---repository, then the rest; within each, ready, working, any other status, then blocked; else in herdr's order. Also
---the first that can be picked in either of the first two groups, else false.
---@param agents changeset.HerdrAgent[]
---@param place changeset.HerdrPlace
---@param real fun(path: string): string Resolves the links in an agent's directory, as git's worktree paths are.
---@return changeset.HerdrAgent[] ranked
---@return integer|false focus
function M._rank(agents, place, real)
  ---@param agent changeset.HerdrAgent
  ---@return integer
  local function group(agent)
    local cwd = dir(agent)
    if place.last and agent.pane_id == place.last.pane and cwd == place.last.dir then
      return 1
    end
    cwd = cwd and real(cwd)
    local inside = cwd
      and vim.iter(place.worktrees):any(function(root)
        return vim.fs.relpath(root, cwd) ~= nil
      end)
    return inside and 2 or 3
  end
  local keyed = vim
    .iter(ipairs(agents))
    :map(function(i, agent)
      return { agent = agent, group(agent), STATUS_RANK[present(agent.agent_status)] or OTHER_RANK, i }
    end)
    :totable()
  table.sort(keyed, function(a, b)
    for k = 1, 3 do
      if a[k] ~= b[k] then
        return a[k] < b[k]
      end
    end
    return false
  end)
  local focus = vim.iter(ipairs(keyed)):find(function(_, k)
    return k[1] <= 2 and k.agent.agent_status ~= BLOCKED
  end)
  return vim.tbl_map(function(k)
    return k.agent
  end, keyed), focus or false
end

---A picker row: a circle in the status's colour, then name, status, where it works, its directory's name and branch,
---and title. An agent at a permission prompt can't be picked, and its row says so in place of its title.
---@param agent changeset.HerdrAgent
---@return changeset.DialogItem
function M._row(agent)
  local labels = type(agent.state_labels) == "table" and agent.state_labels or {}
  local status = present(agent.agent_status)
  local cwd = dir(agent)
  ---@type changeset.DialogItem
  local row = {
    icon = { STATUS, STATUS_HL[status] or render.META_HL },
    cells = {
      { M._name(agent) },
      { present(status and labels[status]) or status or "" },
      { cwd and vim.fs.basename(cwd) or "" },
      { agent_branch(agent) or "" },
    },
  }
  if status == BLOCKED then
    row.unavailable = "answer its prompt first"
  else
    table.insert(row.cells, { present(agent.title) or "" })
  end
  return row
end

---Why `pane` cannot take a paste now, judged from a fresh agent list, or nil when it can.
---@param agents changeset.HerdrAgent[]
---@param pane string
---@param name string
---@return string?
function M._unready(agents, pane, name)
  for _, a in ipairs(agents) do
    if a.pane_id == pane then
      return a.agent_status == BLOCKED and ("answer %s's prompt first"):format(name) or nil
    end
  end
  return name .. " closed"
end

---`text` as one bracketed paste, so its newlines do not reach the agent as Enter.
---@param text string
---@return string
function M._bracket(text)
  local body, n = text, 1
  while n > 0 do
    body, n = body:gsub(vim.pesc(STOP), "")
  end
  return START .. body .. STOP
end

---Runs `herdr args…`, calling back on the main loop with its decoded `result`, or the
---failure's error code ("" when there is none).
---@param args string[]
---@param cb fun(result: table?, code: string?)
local function herdr(args, cb)
  -- A spawn can fail even after the executable check: the binary gone since, or an argv over the OS's limit.
  local started = pcall(
    vim.system,
    vim.list_extend({ "herdr" }, args),
    { text = true, timeout = TIMEOUT },
    vim.schedule_wrap(function(res)
      if res.code ~= 0 then
        local ok, env = pcall(vim.json.decode, res.stderr or "")
        cb(nil, ok and type(env) == "table" and type(env.error) == "table" and env.error.code or "")
        return
      end
      local ok, out = pcall(vim.json.decode, res.stdout or "", { luanil = { object = true, array = true } })
      cb(ok and type(out) == "table" and out.result or {}, nil)
    end)
  )
  if not started then
    vim.schedule(function()
      cb(nil, "")
    end)
  end
end

---@param cb fun(agents: changeset.HerdrAgent[]?)
local function list_agents(cb)
  herdr({ "agent", "list" }, function(result)
    cb(result and result.agents or nil)
  end)
end

---Re-checks `agent` is ready, pastes `text`, then focuses its pane.
---@param text string
---@param agent changeset.HerdrAgent
---@param cb fun(err: string?, agent: string?)
local function deliver(text, agent, cb)
  local name = M._name(agent)
  list_agents(function(agents)
    if not agents then
      return cb("herdr did not list its agents")
    end
    local why = M._unready(agents, agent.pane_id, name)
    if why then
      return cb(why)
    end
    herdr({ "pane", "send-text", agent.pane_id, M._bracket(text) }, function(_, code)
      if code then
        return cb(code == "pane_not_found" and name .. " closed" or "herdr refused the paste")
      end
      herdr({ "agent", "focus", agent.pane_id }, function()
        cb(nil, name)
      end)
    end)
  end)
end

---@param root string
---@return string
local function branch_key(root)
  return comment_store.branch(root) or ""
end

---Every worktree of the repository at `root`, as `git worktree list` names them, its own included.
---@param root string
---@return string[]
local function worktrees(root)
  local out = {}
  for _, line in ipairs(git.lines({ "git", "worktree", "list", "--porcelain" }, root)) do
    out[#out + 1] = line:match("^worktree (.+)")
  end
  return out
end

---@param path string
---@return string
local function real(path)
  return vim.uv.fs_realpath(path) or path
end

---@param candidates changeset.HerdrAgent[]
---@param opts changeset.HerdrSendOpts
---@param cb fun(agent: changeset.HerdrAgent?)
local function pick(candidates, opts, cb)
  local last = (last_agent[opts.root] or {})[branch_key(opts.root)]
  local ranked, focus = M._rank(candidates, { worktrees = worktrees(opts.root), last = last }, real)
  dialog.choose(
    { title = opts.title, items = vim.tbl_map(M._row, ranked), action = "submit", focus = focus },
    function(index)
      cb(index and ranked[index])
    end
  )
end

---Sends `text` to an AI agent in this herdr workspace: straight to the only one, else to the one picked in a
---dialog. Pastes it into the agent's prompt unsent, then focuses the agent's pane.
---@param text string
---@param opts changeset.HerdrSendOpts
---@param cb fun(err: string?, agent: string?) On the main loop. `agent` names who got it on success;
---`err` is a short sentence for `vim.notify`, without a "Changeset:" prefix; both nil when the pick was cancelled.
function M.send(text, opts, cb)
  ---@param why string
  local function refuse(why)
    vim.schedule(function()
      cb(why)
    end)
  end
  local workspace = present(vim.env.HERDR_WORKSPACE_ID)
  if not workspace then
    return refuse("not inside a herdr pane, so there's no agent to paste it into")
  end
  if vim.fn.executable("herdr") ~= 1 then
    return refuse("herdr isn't on PATH, so there's no agent to paste it into")
  end
  list_agents(function(agents)
    if not agents then
      return cb("herdr did not list its agents")
    end
    local candidates = M._candidates(agents, workspace, vim.env.HERDR_PANE_ID)
    ---@param agent changeset.HerdrAgent
    local function to(agent)
      deliver(text, agent, function(err, name)
        if not err then
          last_agent[opts.root] = last_agent[opts.root] or {}
          last_agent[opts.root][branch_key(opts.root)] = { pane = agent.pane_id, dir = dir(agent) }
        end
        cb(err, name)
      end)
    end
    if #candidates == 0 then
      return cb("no agent in this herdr workspace")
    elseif #candidates == 1 then
      return to(candidates[1])
    end
    -- herdr answers well after the key that asked, by when the user may be typing; the picker's keys are Normal mode's.
    vim.cmd.stopinsert()
    pick(candidates, opts, function(choice)
      if not choice then
        return cb(nil, nil)
      end
      to(choice)
    end)
  end)
end

return M
