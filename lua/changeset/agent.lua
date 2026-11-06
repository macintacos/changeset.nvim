---Hands text to an AI agent in another pane of the same Rex session.
local comment_store = require("changeset.comment_store")
local dialog = require("changeset.dialog")
local git = require("changeset.git")
local highlights = require("changeset.highlights")
local process = require("changeset.process")

local M = {}

---A status a program in a pane reported through OSC 7501.
---@class changeset.RexRecord
---@field id string? Absent on the root record, the program's own status.
---@field state string?
---@field effective_app string?
---@field owner { pid: integer, name: string }? The pane's foreground process when the report arrived.

---A pane of the session, as `LIST` reports it.
---@class changeset.RexPane
---@field block_id string
---@field label string?
---@field records changeset.RexRecord[]? Root record first.
---@field foreground { pid: integer, name: string, cwd: string? }?

---@class changeset.Agent
---@field block string
---@field app string The program, such as claude-code, which names the agent in a picker row or a message.
---@field status string?
---@field title string? The pane's label, which an agent such as Claude Code sets to its conversation's title.
---@field cwd string?
---@field branch string? Checked out at `cwd`.

---@class changeset.AgentSendOpts
---@field title string The agent picker's title, which says what goes.
---@field root string The repository the text is about, whose agents the picker lists first.

---@class changeset.AgentLast The agent a repository's text last went to.
---@field block string
---@field dir string? Where it worked then.

---@class changeset.AgentPlace What ranks the agents in the picker.
---@field worktrees string[] Where the repository is checked out, its own root included.
---@field last changeset.AgentLast?

local TIMEOUT = 5000
-- rex's exit status when a target is not found.
local NOT_FOUND = 3
-- Runs inside `rex do`, in Rex's own Lua, not Neovim's.
local LIST = [[
local terminal = "com.superlogical.terminal"
local panes = {}
for _, block in ipairs(rex.session.list_blocks({}).blocks) do
  if block.creator_name == terminal then
    local id = { block_id = block.block_id }
    panes[#panes + 1] = {
      block_id = block.block_id,
      label = block.label,
      records = (rex.block.call(terminal, "program_status", id) or {}).records,
      foreground = (rex.block.call(terminal, "process", id) or {}).foreground,
    }
  end
end
return { panes = panes }
]]
-- The status of an agent at a permission prompt, which silently drops a paste; any other queues it in the input.
local BLOCKED = "blocked"
local STATUS = "●"
-- Each status's colour in the picker; any other, such as error, takes the meta colour.
local STATUS_HL =
  { idle = "DiagnosticOk", done = "DiagnosticOk", working = "DiagnosticWarn", blocked = "DiagnosticError" }
-- Each status's place within a group of the picker's rows: ready first, blocked last, any other before blocked.
local STATUS_RANK = { idle = 1, done = 1, working = 2, blocked = 4 }
local OTHER_RANK = 3

---The agent each repository's text last went to in this Neovim, by root, then branch ("" for none).
---@type table<string, table<string, changeset.AgentLast>>
local last_agent = {}

---`value` when it is a non-empty string, else nil.
---@param value any
---@return string?
local function present(value)
  return type(value) == "string" and value ~= "" and value or nil
end

---The pane's own status while the program that reported it is still in its foreground: Rex keeps an idle or done
---status after its program exits.
---@param pane changeset.RexPane
---@return changeset.RexRecord?
local function live_status(pane)
  local record, fg = (pane.records or {})[1], pane.foreground
  if not (record and record.id == nil and record.owner and fg) then
    return nil
  end
  return record.owner.pid == fg.pid and record.owner.name == fg.name and record or nil
end

---The agents in `panes` other than `own`: those whose foreground program reports a status naming itself, in Rex's
---order.
---@param panes changeset.RexPane[]
---@param own string?
---@param branch_at fun(dir: string): string?
---@return changeset.Agent[]
function M._agents(panes, own, branch_at)
  local agents = {}
  for _, pane in ipairs(panes) do
    local status = live_status(pane)
    local app = status and present(status.effective_app)
    if status and app and pane.block_id ~= own then
      local cwd = present((pane.foreground or {}).cwd)
      agents[#agents + 1] = {
        block = pane.block_id,
        app = app,
        status = present(status.state),
        title = present(pane.label),
        cwd = cwd,
        branch = cwd and branch_at(cwd),
      }
    end
  end
  return agents
end

---`agents` in the picker's order: the one `place.last` names while it works where it did, then those working in the
---repository, then the rest; within each, ready, working, any other status, then blocked; else in Rex's order. Also
---the first that can be picked in either of the first two groups, else false.
---@param agents changeset.Agent[]
---@param place changeset.AgentPlace
---@param real fun(path: string): string Resolves the links in an agent's directory, as git's worktree paths are.
---@return changeset.Agent[] ranked
---@return integer|false focus
function M._rank(agents, place, real)
  ---@param agent changeset.Agent
  ---@return integer
  local function group(agent)
    local cwd = agent.cwd
    if place.last and agent.block == place.last.block and cwd == place.last.dir then
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
      return { agent = agent, group(agent), STATUS_RANK[agent.status] or OTHER_RANK, i }
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
    return k[1] <= 2 and k.agent.status ~= BLOCKED
  end)
  return vim.tbl_map(function(k)
    return k.agent
  end, keyed), focus or false
end

---A picker row: a circle in the status's colour, then name, status, where it works, its directory's name and branch,
---and title. An agent at a permission prompt can't be picked, and its row says so in place of its title.
---@param agent changeset.Agent
---@return changeset.DialogItem
function M._row(agent)
  ---@type changeset.DialogItem
  local row = {
    icon = { STATUS, STATUS_HL[agent.status] or highlights.META_HL },
    cells = {
      { agent.app },
      { agent.status or "" },
      { agent.cwd and vim.fs.basename(agent.cwd) or "" },
      { agent.branch or "" },
    },
  }
  if agent.status == BLOCKED then
    row.unavailable = "answer its prompt first"
  else
    table.insert(row.cells, { agent.title or "" })
  end
  return row
end

---Why `block` cannot take a paste now, judged from a fresh agent list, or nil when it can.
---@param agents changeset.Agent[]
---@param block string
---@param name string
---@return string?
function M._unready(agents, block, name)
  for _, a in ipairs(agents) do
    if a.block == block then
      return a.status == BLOCKED and ("answer %s's prompt first"):format(name) or nil
    end
  end
  return name .. " closed"
end

---Runs `rex args…`, calling back on the main loop with its decoded output, or nil and whether its target was missing.
---@param args string[]
---@param stdin string?
---@param cb fun(result: table?, missing: boolean?)
local function rex(args, stdin, cb)
  process.run(vim.list_extend({ "rex" }, args), { stdin = stdin, timeout = TIMEOUT }, function(res)
    if res.code ~= 0 then
      return cb(nil, res.code == NOT_FOUND)
    end
    local ok, out = pcall(vim.json.decode, res.stdout, { luanil = { object = true, array = true } })
    cb(ok and type(out) == "table" and out or {}, nil)
  end)
end

---The branch checked out in the repository holding `dir`.
---@param dir string
---@return string?
local function branch_at(dir)
  local root = vim.fs.root(dir, ".git")
  return root and comment_store.branch(root)
end

---Where Neovim runs: its Rex session and its own pane.
---@class changeset.RexHere
---@field session string
---@field block string?

---@param here changeset.RexHere
---@param cb fun(agents: changeset.Agent[]?)
local function list_agents(here, cb)
  rex({ "do", "-s", here.session, "-e", LIST }, nil, function(result)
    cb(result and M._agents(result.panes or {}, here.block, branch_at))
  end)
end

---Re-checks `agent` is ready, pastes `text`, then focuses its pane.
---@param text string
---@param agent changeset.Agent
---@param here changeset.RexHere
---@param cb fun(err: string?, agent: string?)
local function deliver(text, agent, here, cb)
  local name = agent.app
  list_agents(here, function(agents)
    if not agents then
      return cb("Rex did not list this session's panes")
    end
    local why = M._unready(agents, agent.block, name)
    if why then
      return cb(why)
    end
    -- A paste event, which Rex brackets when the agent asked for bracketed paste, so newlines do not reach it as Enter.
    local paste = vim.json.encode({ block_id = agent.block, event = { type = "paste", payload = { text = text } } })
    rex({ "api", "call", "-s", here.session, "block.event", "-" }, paste, function(pasted, missing)
      if not pasted then
        return cb(missing and name .. " closed" or "Rex refused the paste")
      end
      rex({ "focus", "-s", here.session, agent.block }, nil, function()
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

---@param candidates changeset.Agent[]
---@param opts changeset.AgentSendOpts
---@param cb fun(agent: changeset.Agent?)
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

---Sends `text` to an AI agent in this Rex session: straight to the only one, else to the one picked in a dialog.
---Pastes it into the agent's prompt unsent, then focuses the agent's pane.
---@param text string
---@param opts changeset.AgentSendOpts
---@param cb fun(err: string?, agent: string?) On the main loop. `agent` names who got it on success;
---`err` is a short sentence for `vim.notify`, without a "Changeset:" prefix; both nil when the pick was cancelled.
function M.send(text, opts, cb)
  ---@param why string
  local function refuse(why)
    vim.schedule(function()
      cb(why)
    end)
  end
  local session = present(vim.env.REX_SESSION)
  if not session then
    return refuse("not inside a Rex pane, so there's no agent to paste it into")
  end
  if vim.fn.executable("rex") ~= 1 then
    return refuse("rex isn't on PATH, so there's no agent to paste it into")
  end
  local here = { session = session, block = present(vim.env.REX_BLOCK) }
  list_agents(here, function(candidates)
    if not candidates then
      return cb("Rex did not list this session's panes")
    end
    ---@param agent changeset.Agent
    local function to(agent)
      deliver(text, agent, here, function(err, name)
        if not err then
          last_agent[opts.root] = last_agent[opts.root] or {}
          last_agent[opts.root][branch_key(opts.root)] = { block = agent.block, dir = agent.cwd }
        end
        cb(err, name)
      end)
    end
    if #candidates == 0 then
      return cb("no agent in this Rex session")
    elseif #candidates == 1 then
      return to(candidates[1])
    end
    -- Rex answers after the key that asked, by when the user may be typing; the picker's keys are Normal mode's.
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
