---What each sidebar key does, and the keymaps that bind them.
---The keys write `query`, `hidden` and the folds in `st` on the session they are handed;
---`changeset.BuildHooks.view` gives those fields their first values.

local Paths = require("changeset.paths")
local build = require("changeset.build")
local help = require("changeset.help")
local icons = require("changeset.icons")
local state = require("changeset.state")
local tree = require("changeset.tree")
local view = require("changeset.view")
local window = require("changeset.window")

-- input() reads a line, so it can never hand one back: free to mean "cancelled".
local CANCELLED = "\r"

local M = {}

---What the sidebar lends its keys.
---@class changeset.ActionHooks
---@field row_at_cursor fun(): changeset.Row? The row under the sidebar's cursor.
---@field draw fun() Redraw the tree from the session's current view state.
---@field pick fun(row: changeset.Row) Mark `row` as the one last opened from the sidebar.
---@field close fun() Dismiss the sidebar.

---The tree `build` keeps, with the sidebar's own fields on it.
---Read it again after anything that can replace the tree: `build.build()`, `vim.wait`, a later callback.
---@return changeset.Session?
local function current()
  return build.current() --[[@as changeset.Session?]]
end

---@param row changeset.Row
---@param open boolean
---@param hooks changeset.ActionHooks
local function set_open(row, open, hooks)
  local session = current()
  assert(session, "changeset: no open session")
  -- A compressed chain hides intermediate rows; a folded row hides its children.
  -- `l` on a compressed row means the first, so it wins while the chain is shut.
  if row.chain and not state.is_chain_open(session.st, row.id) and open then
    state.set_chain_open(session.st, row.id, true)
  elseif row.chain and state.is_chain_open(session.st, row.id) and not open then
    state.set_chain_open(session.st, row.id, false)
  else
    state.set_collapsed(session.st, row.id, not open)
  end
  hooks.draw()
end

---@param how "reuse"|"vsplit"|"split"|"tab"
---@param hooks changeset.ActionHooks
local function commit(how, hooks)
  local session = current()
  local row = hooks.row_at_cursor()
  if not row or row.kind == "section" then
    return
  end
  if row.kind == "file" and row.status == "deleted" then
    return vim.notify(row.path .. " was deleted on this branch", vim.log.levels.INFO)
  end
  assert(session, "changeset: no open session")
  if window.commit(session.root .. "/" .. row.path, row.lnum or 1, how) then
    hooks.pick(row)
  end
end

---@param delta integer
---@param preview fun()
local function step(delta, preview)
  local session = current()
  local win = window.win()
  if not (session and win) then
    return
  end
  local lnum = state._step(session.visible, vim.api.nvim_win_get_cursor(win)[1], delta)
  vim.api.nvim_win_set_cursor(win, { lnum, 0 })
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
---@param open_session changeset.Session
---@param hooks changeset.ActionHooks
local function open_kind_menu(open_session, hooks)
  require("changeset.menu").open({
    root = open_session.root,
    branch = open_session.branch,
    file = open_session.file,
    counts = view.kind_counts(open_session.rows),
    hidden = open_session.hidden,
    icon = function(symbol_kind)
      return icons.get("lsp", symbol_kind)
    end,
    sidebar = assert(window.win(), "changeset: sidebar is closed"),
    on_change = function(hidden)
      open_session.hidden = hidden
      hooks.draw()
    end,
  })
end

---Narrow the tree from the command line, restoring the previous query on cancel.
---@param open_session changeset.Session
---@param hooks changeset.ActionHooks
local function prompt_filter(open_session, hooks)
  local previous_query = open_session.query
  local group = vim.api.nvim_create_augroup("changeset.filter", { clear = true })
  -- input() edits on the command line, so every keystroke is a CmdlineChanged
  -- — which is what lets the tree narrow as it is typed rather than at <CR>.
  vim.api.nvim_create_autocmd("CmdlineChanged", {
    group = group,
    desc = "changeset: filter the tree on each keystroke of the filter prompt",
    callback = function()
      open_session.query = vim.fn.getcmdline()
      hooks.draw()
      vim.cmd("redraw")
    end,
  })

  local ok, typed = pcall(vim.fn.input, {
    prompt = "Filter changes: ",
    default = previous_query,
    cancelreturn = CANCELLED,
  })
  vim.api.nvim_del_augroup_by_id(group)

  open_session.query = (ok and typed ~= CANCELLED) and typed or previous_query
  hooks.draw()
end

---Put the cursor on the nearest section header in `delta`'s direction, if there is one.
---@param open_session changeset.Session
---@param delta integer 1 or -1.
local function to_section(open_session, delta)
  local win = window.win()
  if not win then
    return
  end
  local lnum = state._section(open_session.visible, vim.api.nvim_win_get_cursor(win)[1], delta)
  vim.api.nvim_win_set_cursor(win, { lnum, 0 })
end

---What `h` does from a row: shut it, or put the cursor on its parent.
---@param open_session changeset.Session
---@param hooks changeset.ActionHooks
local function collapse_or_parent(open_session, hooks)
  local row, win = hooks.row_at_cursor(), window.win()
  if not (row and win) then
    return
  end
  local action, parent_lnum = state._outward(open_session.visible, vim.api.nvim_win_get_cursor(win)[1])
  if action == "collapse" then
    set_open(row, false, hooks)
  elseif action == "parent" then
    vim.api.nvim_win_set_cursor(win, { parent_lnum, 0 })
  end
end

---@param open_session changeset.Session
---@param hooks changeset.ActionHooks
local function collapse_all_files(open_session, hooks)
  state.collapse_all(
    open_session.st,
    vim.tbl_map(function(row)
      return row.id
    end, tree.files(open_session.rows))
  )
  hooks.draw()
end

---Keeps every section's fold, including one whose section is empty for now.
---@param open_session changeset.Session
---@param hooks changeset.ActionHooks
local function expand_all_files(open_session, hooks)
  state.expand_all(open_session.st, tree.section_ids())
  hooks.draw()
end

---Bind `keys` on the sidebar's buffer. `?` lists exactly these and the step keys.
---@param buf integer
---@param keys changeset.Config.Keymaps
---@param hooks changeset.ActionHooks
function M.set_keymaps(buf, keys, hooks)
  local set, own = help.mapper(buf)
  -- The window can outlive the session: a `build()` for another repository lets go
  -- of the tree while a sidebar stands. Handing the session down rather than letting
  -- handlers reach for it means the check that it exists is the same line that
  -- passes it on.
  ---@param lhs string|false
  ---@param fn fun(open_session: changeset.Session, hooks: changeset.ActionHooks)
  ---@param desc string
  local function map(lhs, fn, desc)
    if not lhs then
      return
    end
    set(lhs, function()
      local session = current()
      if session then
        fn(session, hooks)
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
  map(keys.expand, function()
    local row = hooks.row_at_cursor()
    if row then
      set_open(row, true, hooks)
    end
  end, "Expand")
  map(keys.collapse, collapse_or_parent, "Collapse, or step out to the parent")
  map(keys.collapse_all, collapse_all_files, "Collapse every file")
  map(keys.expand_all, expand_all_files, "Expand every file")
  map(keys.next_section, function(open_session)
    to_section(open_session, 1)
  end, "Next section")
  map(keys.prev_section, function(open_session)
    to_section(open_session, -1)
  end, "Previous section")
  map(keys.refresh, build.refresh, "Rebuild the tree")
  map(keys.yank, function()
    local row = hooks.row_at_cursor()
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
  map(keys.filter_kinds, open_kind_menu, "Filter by symbol kind")
  map(keys.filter, prompt_filter, "Filter the tree")
end

return M
