---What each sidebar key does, and the keymaps that bind them.
---The fold, step and filter keys ask the sidebar's view, then move the cursor or redraw; on a comment row the jump
---keys open what it lists, and the delete key deletes it.

local Paths = require("changeset.paths")
local build = require("changeset.build")
local draw = require("changeset.draw")
local help = require("changeset.help")
local icons = require("changeset.icons")
local reviewing = require("changeset.reviewing")
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
---@field back? fun(row: changeset.Row?) Told, before focus goes back to the sidebar, which row a step from it opened.

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
---@return changeset.Row? committed The row opened, if any.
local function commit(how, hooks)
  local state = sidebar_state.current()
  local row = draw.row_at_cursor()
  if not row or row.kind == "section" then
    return
  end
  if row.kind == "file" and row.status == "deleted" then
    return vim.notify(row.path .. " was deleted on this branch", vim.log.levels.INFO)
  end
  assert(state, "changeset: no tree built yet")
  if window.commit(state.tree.root .. "/" .. row.path, row.lnum or 1, how) then
    hooks.pick(row)
    return row
  end
end

---Open what a comment row lists in the window a commit left focused.
---@param row changeset.Row?
local function open_comment(row)
  if row and row.review_comment then
    reviewing.open(row.review_comment)
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

---Where a row opens, as `commit` opens it.
---@param row changeset.Row
---@return string
local function place_of(row)
  return ("%s:%d"):format(row.path, row.lnum or 1)
end

---The file of the tree, and the line, that the window a commit opens into stands on; nil when it holds none.
---@param root string
---@return string? path
---@return integer line
local function standing(root)
  local win = window.peek_target()
  if not win then
    return nil, 0
  end
  local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
  local path = name ~= "" and vim.fs.relpath(root, vim.fs.normalize(name)) or nil
  return path, vim.api.nvim_win_get_cursor(win)[1]
end

---The row a step `delta` starts from: the cursor's when it opens where the window stands. Else, among that file's
---rows, the last at or above its line, or the row just below that for a step back from past it, so the row is the
---first place; above the file's first row, just before it for a step on and at it for a step back. The sidebar can
---be on a shallower row, such as the file's, or another file's, than where you are.
---@param state changeset.SidebarState
---@param lnum integer The cursor's row.
---@param path string?
---@param line integer
---@param delta integer
---@return integer
local function start_row(state, lnum, path, line, delta)
  local row = state.view:row(lnum)
  if not path or (row and place_of(row) == ("%s:%d"):format(path, line)) then
    return lnum
  end
  local first, found
  for i, each in ipairs(state.view:visible()) do
    if each.path == path and each.kind ~= "section" and each.kind ~= "comment" then
      first = first or i
      if (each.lnum or 1) <= line then
        found = i
      end
    end
  end
  if not found then
    return first and (delta > 0 and first - 1 or first) or lnum
  end
  local found_line = assert(state.view:row(found)).lnum or 1
  return delta < 0 and found_line < line and found + 1 or found
end

---The row `count` places past the sidebar's cursor, down for a positive `count`: each place a row that opens
---somewhere other than the last, starting from where the window it opens into stands. A deleted file's row opens
---nowhere, so it is never one. Stops at the last such row.
---@param state changeset.SidebarState
---@param lnum integer
---@param count integer
---@param here string? Where the window stands, as `place_of` spells it.
---@return integer
local function placed(state, lnum, count, here)
  local delta = count > 0 and 1 or -1
  local to = lnum
  for _ = 1, math.abs(count) do
    local at = to
    repeat
      local next_lnum = state.view:step(at, delta)
      if next_lnum == at then
        return to
      end
      at = next_lnum
      local row = assert(state.view:row(at))
    until not (row.kind == "file" and row.status == "deleted") and place_of(row) ~= here
    to, here = at, place_of(assert(state.view:row(at)))
  end
  return to
end

---Steps the sidebar's cursor `count` places, then opens that row as `<CR>` does, without its review comment, in
---the window the sidebar opens changes in. From a file window or the sidebar, focus stays there; from a window that
---holds no file, it goes where the row opened.
---@param count integer Down for positive.
---@param hooks changeset.ActionHooks
function M.open_step(count, hooks)
  local state, lnum = sidebar_state.current(), cursor()
  if not (state and lnum) then
    return
  end
  local path, line = standing(state.tree.root)
  local from = start_row(state, lnum, path, line, count > 0 and 1 or -1)
  local to = placed(state, from, count, path and ("%s:%d"):format(path, line))
  if to == from then
    -- Not wrapped, so a run of `.` stops here rather than looping.
    return vim.api.nvim_echo({ { count > 0 and "no next change" or "no previous change" } }, false, {})
  end
  local focus = vim.api.nvim_get_current_win()
  move(to)
  local row = commit("reuse", hooks)
  if focus == window.win() and row then
    if hooks.back then
      hooks.back(row)
    end
    vim.api.nvim_set_current_win(focus)
  end
end

---The step keys bound while the sidebar stands, each with the global mapping it replaced.
---@type { lhs: string, prior: vim.api.keyset.get_keymap? }[]
local step_bindings = {}

local NEXT_DESC = "Next change (Changeset)"
local PREV_DESC = "Previous change (Changeset)"

---The global normal-mode mapping for `lhs`, if any.
---@param lhs string
---@return vim.api.keyset.get_keymap?
local function global_mapping(lhs)
  -- Global only: maparg() prefers a buffer-local mapping, which mapset() would restore onto the buffer current at close.
  return vim.iter(vim.api.nvim_get_keymap("n")):find(function(keymap)
    return vim.keycode(keymap.lhs) == vim.keycode(lhs)
  end)
end

---Remove the step keys and put back what they replaced; a map set over one since stays. Safe to repeat: `close` also
---runs with no sidebar open.
function M.unbind_step_keys()
  -- Newest first: a key bound twice records changeset's own first mapping as the second's prior.
  for i = #step_bindings, 1, -1 do
    local binding = step_bindings[i]
    local current = global_mapping(binding.lhs)
    if not current or current.desc == NEXT_DESC or current.desc == PREV_DESC then
      pcall(vim.keymap.del, "n", binding.lhs)
      if binding.prior then
        vim.fn.mapset(binding.prior)
      end
    end
  end
  step_bindings = {}
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
  bind_step_key(keys.next, NEXT_DESC, function()
    step(1, preview)
  end)
  bind_step_key(keys.prev, PREV_DESC, function()
    step(-1, preview)
  end)
end

---Open the symbol-kind filter menu, redrawing as kinds are toggled.
---@param state changeset.SidebarState
---@param redraw fun() Redraw the tree.
local function open_kind_menu(state, redraw)
  require("changeset.menu").open({
    root = state.tree.root,
    branch = state.tree.branch,
    file = state.file,
    counts = view.kind_counts(state.rows),
    hidden = state.view:hidden(),
    icon = function(symbol_kind)
      return icons.get("lsp", symbol_kind)
    end,
    sidebar = assert(window.win(), "changeset: sidebar is closed"),
    on_change = function(hidden)
      state.view:hide(hidden)
      redraw()
    end,
  })
end

---Narrow the tree from the command line, restoring the previous query on cancel.
---@param state changeset.SidebarState
---@param redraw fun() Redraw the tree.
local function prompt_filter(state, redraw)
  local previous_query = state.view:query()
  local group = vim.api.nvim_create_augroup("changeset.filter", { clear = true })
  -- input() edits on the command line, so every keystroke is a CmdlineChanged
  -- — which is what lets the tree narrow as it is typed rather than at <CR>.
  vim.api.nvim_create_autocmd("CmdlineChanged", {
    group = group,
    desc = "changeset: filter the tree on each keystroke of the filter prompt",
    callback = function()
      state.view:narrow(vim.fn.getcmdline())
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

  state.view:narrow((ok and typed ~= CANCELLED) and typed or previous_query)
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
  -- A build() for another repository replaces the tree while a sidebar stands, so each
  -- handler takes the state current when its key is pressed, never one captured when it
  -- was bound.
  ---@param lhs string|false
  ---@param fn fun(state: changeset.SidebarState, hooks: changeset.ActionHooks)
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
    open_comment(commit("reuse", hooks))
  end, "Go to this change")
  -- The commit leaves the cursor in the window it jumped to, and `close` keeps
  -- focus where it already is, so the sidebar goes without taking the jump back.
  map(keys.jump_close, function()
    local row = commit("reuse", hooks)
    hooks.close()
    open_comment(row)
  end, "Go to this change and close the tree")
  map(keys.jump_vsplit, function()
    open_comment(commit("vsplit", hooks))
  end, "Go to this change in a vertical split")
  map(keys.jump_split, function()
    open_comment(commit("split", hooks))
  end, "Go to this change in a split")
  map(keys.jump_tab, function()
    open_comment(commit("tab", hooks))
  end, "Go to this change in a new tab")
  map(keys.delete_comment, function()
    local row = draw.row_at_cursor()
    if row and row.review_comment then
      reviewing.ask_delete(row.review_comment)
    end
  end, "Delete this review comment")
  map(keys.close, hooks.close, "Close the tree")
  map(keys.expand, function(state)
    local lnum = cursor()
    if lnum and state.view:open(lnum) then
      redraw()
    end
  end, "Expand")
  map(keys.collapse, function(state)
    local lnum = cursor()
    if not lnum then
      return
    end
    local parent_lnum, shut = state.view:step_out(lnum)
    if parent_lnum then
      move(parent_lnum)
    elseif shut then
      redraw()
    end
  end, "Collapse, or step out to the parent")
  map(keys.collapse_all, function(state)
    state.view:fold_files(state.rows)
    redraw()
  end, "Collapse every file")
  map(keys.expand_all, function(state)
    state.view:unfold_files()
    redraw()
  end, "Expand every file")
  map(keys.next_section, function(state)
    local lnum = cursor()
    if lnum then
      move(state.view:step_section(lnum, 1))
    end
  end, "Next section")
  map(keys.prev_section, function(state)
    local lnum = cursor()
    if lnum then
      move(state.view:step_section(lnum, -1))
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
  map(keys.filter_kinds, function(state)
    open_kind_menu(state, redraw)
  end, "Filter by symbol kind")
  map(keys.filter, function(state)
    prompt_filter(state, redraw)
  end, "Filter the tree")
end

return M
