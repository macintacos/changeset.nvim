---What each sidebar key does, and the keymaps that bind them.
---The fold, step and filter keys ask the sidebar's view, then move the cursor or redraw.

local Paths = require("changeset.paths")
local build = require("changeset.build")
local draw = require("changeset.draw")
local help = require("changeset.help")
local icons = require("changeset.icons")
local sidebar_state = require("changeset.sidebar_state")
local view = require("changeset.view")
local window = require("changeset.window")

-- input() reads a line, so it can never hand one back: free to mean "cancelled".
local CANCELLED = "\r"

local M = {}

---What the sidebar lends its keys.
---@class changeset.ActionHooks
---@field pick fun(row: changeset.Row) Mark `row` as the one last opened from the sidebar.
---@field close fun() Dismiss the sidebar.

---The sidebar's cursor line, while it stands.
---@return integer?
local function cursor()
  local win = window.win()
  return win and vim.api.nvim_win_get_cursor(win)[1]
end

---@param lnum integer
local function move(lnum)
  vim.api.nvim_win_set_cursor(assert(window.win(), "changeset: sidebar is closed"), { lnum, 0 })
end

---@param how "reuse"|"vsplit"|"split"|"tab"
---@param hooks changeset.ActionHooks
local function commit(how, hooks)
  local state = sidebar_state.current()
  local row = draw.row_at_cursor()
  if not row or row.kind == "section" then
    return
  end
  if row.kind == "file" and row.status == "deleted" then
    return vim.notify(row.path .. " was deleted on this branch", vim.log.levels.INFO)
  end
  assert(state, "changeset: no open session")
  if window.commit(state.tree.root .. "/" .. row.path, row.lnum or 1, how) then
    hooks.pick(row)
  end
end

---@param delta integer
---@param preview fun()
local function step(delta, preview)
  local state, lnum = sidebar_state.current(), cursor()
  if not (state and lnum) then
    return
  end
  move(state.view:step(lnum, delta))
  preview()
end

---The step keys bound while the sidebar stands, each with the global mapping it replaced.
---@type { lhs: string, prior: vim.api.keyset.get_keymap? }[]
local step_bindings = {}

---Remove the step keys and put back what they replaced. Safe to repeat: `close` also runs with no sidebar open.
function M.unbind_step_keys()
  -- Newest first: a key bound twice records changeset's own first mapping as the second's prior.
  for i = #step_bindings, 1, -1 do
    local binding = step_bindings[i]
    pcall(vim.keymap.del, "n", binding.lhs)
    if binding.prior then
      vim.fn.mapset(binding.prior)
    end
  end
  step_bindings = {}
end

---The global normal-mode mapping for `lhs`, if any.
---@param lhs string
---@return vim.api.keyset.get_keymap?
local function global_mapping(lhs)
  -- Global only: maparg() prefers a buffer-local mapping, which mapset() would restore onto the buffer current at close.
  return vim.iter(vim.api.nvim_get_keymap("n")):find(function(keymap)
    return vim.keycode(keymap.lhs) == vim.keycode(lhs)
  end)
end

---@param lhs (string|false)?
---@param desc string
---@param on_press fun()
local function bind_step_key(lhs, desc, on_press)
  if not lhs then
    return
  end
  step_bindings[#step_bindings + 1] = { lhs = lhs, prior = global_mapping(lhs) }
  vim.keymap.set("n", lhs, on_press, { desc = desc })
end

---Bind the `next` / `prev` keys globally, remembering the global mapping each replaces.
---Unbinds first: a closed sidebar's scheduled close may not have run yet.
---@param keys changeset.Config.Keymaps
---@param preview fun() Preview the row under the sidebar's cursor.
function M.bind_step_keys(keys, preview)
  M.unbind_step_keys()
  bind_step_key(keys.next, "Next change (Changeset)", function()
    step(1, preview)
  end)
  bind_step_key(keys.prev, "Previous change (Changeset)", function()
    step(-1, preview)
  end)
end

---Open the symbol-kind filter menu, redrawing as kinds are toggled.
---@param open_session changeset.SidebarState
---@param redraw fun() Redraw the tree.
local function open_kind_menu(open_session, redraw)
  require("changeset.menu").open({
    root = open_session.tree.root,
    branch = open_session.tree.branch,
    file = open_session.file,
    counts = view.kind_counts(open_session.rows),
    hidden = open_session.view:hidden(),
    icon = function(symbol_kind)
      return icons.get("lsp", symbol_kind)
    end,
    sidebar = assert(window.win(), "changeset: sidebar is closed"),
    on_change = function(hidden)
      open_session.view:hide(hidden)
      redraw()
    end,
  })
end

---Narrow the tree from the command line, restoring the previous query on cancel.
---@param open_session changeset.SidebarState
---@param redraw fun() Redraw the tree.
local function prompt_filter(open_session, redraw)
  local previous_query = open_session.view:query()
  local group = vim.api.nvim_create_augroup("changeset.filter", { clear = true })
  -- input() edits on the command line, so every keystroke is a CmdlineChanged
  -- — which is what lets the tree narrow as it is typed rather than at <CR>.
  vim.api.nvim_create_autocmd("CmdlineChanged", {
    group = group,
    desc = "changeset: filter the tree on each keystroke of the filter prompt",
    callback = function()
      open_session.view:narrow(vim.fn.getcmdline())
      redraw()
      vim.cmd("redraw")
    end,
  })

  local ok, typed = pcall(vim.fn.input, {
    prompt = "Filter changes: ",
    default = previous_query,
    cancelreturn = CANCELLED,
  })
  vim.api.nvim_del_augroup_by_id(group)

  open_session.view:narrow((ok and typed ~= CANCELLED) and typed or previous_query)
  redraw()
end

---Bind `keys` on the sidebar's buffer. `?` lists exactly these and the step keys.
---@param buf integer
---@param keys changeset.Config.Keymaps
---@param hooks changeset.ActionHooks
function M.set_keymaps(buf, keys, hooks)
  local set, own = help.mapper(buf)
  local function redraw()
    draw.draw(keys.filter_kinds)
  end
  -- The window can outlive the tree: a `build()` for another repository lets go
  -- of it while a sidebar stands. Handing the sidebar's state down rather than letting
  -- handlers reach for it means the check that it exists is the same line that
  -- passes it on.
  ---@param lhs string|false
  ---@param fn fun(open_session: changeset.SidebarState, hooks: changeset.ActionHooks)
  ---@param desc string
  local function map(lhs, fn, desc)
    if not lhs then
      return
    end
    set(lhs, function()
      local state = sidebar_state.current()
      if state then
        fn(state, hooks)
      end
    end, desc)
  end

  map(keys.jump, function()
    commit("reuse", hooks)
  end, "Go to this change")
  -- The commit leaves the cursor in the window it jumped to, and `close` keeps
  -- focus where it already is, so the sidebar goes without taking the jump back.
  map(keys.jump_close, function()
    commit("reuse", hooks)
    hooks.close()
  end, "Go to this change and close the tree")
  map(keys.jump_vsplit, function()
    commit("vsplit", hooks)
  end, "Go to this change in a vertical split")
  map(keys.jump_split, function()
    commit("split", hooks)
  end, "Go to this change in a split")
  map(keys.jump_tab, function()
    commit("tab", hooks)
  end, "Go to this change in a new tab")
  map(keys.close, hooks.close, "Close the tree")
  map(keys.expand, function(open_session)
    local lnum = cursor()
    if lnum and open_session.view:open(lnum) then
      redraw()
    end
  end, "Expand")
  map(keys.collapse, function(open_session)
    local lnum = cursor()
    if not lnum then
      return
    end
    local parent_lnum, shut = open_session.view:step_out(lnum)
    if parent_lnum then
      move(parent_lnum)
    elseif shut then
      redraw()
    end
  end, "Collapse, or step out to the parent")
  map(keys.collapse_all, function(open_session)
    open_session.view:fold_files(open_session.rows)
    redraw()
  end, "Collapse every file")
  map(keys.expand_all, function(open_session)
    open_session.view:unfold_files()
    redraw()
  end, "Expand every file")
  map(keys.next_section, function(open_session)
    local lnum = cursor()
    if lnum then
      move(open_session.view:step_section(lnum, 1))
    end
  end, "Next section")
  map(keys.prev_section, function(open_session)
    local lnum = cursor()
    if lnum then
      move(open_session.view:step_section(lnum, -1))
    end
  end, "Previous section")
  map(keys.refresh, build.refresh, "Rebuild the tree")
  map(keys.yank, function()
    local row = draw.row_at_cursor()
    if row and row.kind ~= "section" then
      Paths.copy(row.lnum and ("%s:%d"):format(row.path, row.lnum) or row.path, "relative path:line")
    end
  end, "Yank path:line")
  map(keys.help, function()
    help.show(
      buf,
      own,
      vim.tbl_map(function(binding)
        return binding.lhs
      end, step_bindings)
    )
  end, "Show these keymaps")
  map(keys.filter_kinds, function(open_session)
    open_kind_menu(open_session, redraw)
  end, "Filter by symbol kind")
  map(keys.filter, function(open_session)
    prompt_filter(open_session, redraw)
  end, "Filter the tree")
end

return M
