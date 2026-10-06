---Hands text to an AI agent in another pane of the same herdr workspace.
local dialog = require("changeset.dialog")
local render = require("changeset.render")

local M = {}

---@class changeset.HerdrAgent
---@field agent string?
---@field agent_status string?
---@field pane_id string
---@field tab_id string?
---@field workspace_id string?
---@field name string?
---@field display_agent string?
---@field title string?
---@field state_labels table<string, string>?

local TIMEOUT = 5000
local START, STOP = "\27[200~", "\27[201~"
-- The status of an agent at a permission prompt, which silently drops a paste; any other queues it in the input.
local BLOCKED = "blocked"
local STATUS = "●"
-- Each status's colour in the picker; any other, such as unknown, takes the meta colour.
local STATUS_HL =
  { idle = "DiagnosticOk", done = "DiagnosticOk", working = "DiagnosticWarn", blocked = "DiagnosticError" }

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

---A picker row: a circle in the status's colour, then name, status, tab label and title, the title blank when the
---label is it, alone or behind herdr's glyph. An agent at a permission prompt can't be picked, and its row says so
---in place of its tab and title.
---@param agent changeset.HerdrAgent
---@param tab_labels table<string, string> Each tab's label by tab id.
---@return changeset.DialogItem
function M._row(agent, tab_labels)
  local labels = type(agent.state_labels) == "table" and agent.state_labels or {}
  local status = present(agent.agent_status)
  ---@type changeset.DialogItem
  local row = {
    icon = { STATUS, STATUS_HL[status] or render.META_HL },
    cells = { { M._name(agent) }, { present(status and labels[status]) or status or "" } },
  }
  if status == BLOCKED then
    row.unavailable = "answer its prompt first"
  else
    local tab, title = present(tab_labels[agent.tab_id]) or "", present(agent.title) or ""
    -- herdr can label a tab after its agent's title, behind the tab's number glyph; the same words twice are noise.
    vim.list_extend(row.cells, { { tab }, { (tab == title or vim.endswith(tab, " " .. title)) and "" or title } })
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

---@param workspace string
---@param candidates changeset.HerdrAgent[]
---@param cb fun(agent: changeset.HerdrAgent?)
local function pick(workspace, candidates, cb)
  herdr({ "tab", "list", "--workspace", workspace }, function(result)
    local labels = {}
    for _, tab in ipairs(result and result.tabs or {}) do
      labels[tab.tab_id] = tab.label
    end
    dialog.choose({
      title = "Submit the review",
      items = vim.tbl_map(function(a)
        return M._row(a, labels)
      end, candidates),
      action = "submit",
    }, function(index)
      cb(index and candidates[index])
    end)
  end)
end

---Sends `text` to an AI agent in this herdr workspace: straight to the only one, else to the one picked in a
---dialog. Pastes it into the agent's prompt unsent, then focuses the agent's pane.
---@param text string
---@param cb fun(err: string?, agent: string?) On the main loop. `agent` names who got it on success;
---`err` is a short sentence for `vim.notify`, without a "Changeset:" prefix; both nil when the pick was cancelled.
function M.send(text, cb)
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
    if #candidates == 0 then
      return cb("no agent in this herdr workspace")
    elseif #candidates == 1 then
      return deliver(text, candidates[1], cb)
    end
    pick(workspace, candidates, function(choice)
      if not choice then
        return cb(nil, nil)
      end
      deliver(text, choice, cb)
    end)
  end)
end

return M
