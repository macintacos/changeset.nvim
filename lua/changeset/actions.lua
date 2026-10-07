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

---What the sidebar lends a step.
---@class changeset.StepHooks : changeset.ActionHooks
---@field redraw fun() Redraw the tree, once a step unfolds the rows over the one it reached.

---What a step counts as a place: any row that opens, or only a changed symbol's, or a file's.
---@alias changeset.StepUnit "change"|"symbol"|"file"

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

---Whether `row` lists a review comment on a whole file, which opens under the row, there being no line to go to.
---@param row changeset.Row?
---@return boolean
local function lists_file_comment(row)
  return row ~= nil and row.review_comment ~= nil and row.review_comment.line == nil
end

---Opens the cursor's row `how`, then the review comment it lists; a whole file's opens under the row instead.
---@param how "reuse"|"vsplit"|"split"|"tab"
---@param hooks changeset.ActionHooks
local function jump(how, hooks)
  local row = draw.row_at_cursor()
  local comment = row and row.review_comment
  if row and comment and not comment.line then
    hooks.pick(row)
    return reviewing.open(comment)
  end
  open_comment(commit(how, hooks))
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
---rows, the one before the first below its line for a step on, or after the last above it for a step back, else the
---file's last or first row: rows aren't in line order, and the first place must be past the line that way. The
---sidebar can be on a shallower row, such as the file's, or another file's, than where you are.
---@param rows changeset.Row[] The rows the step walks.
---@param at integer Where the sidebar's cursor row is among them.
---@param path string?
---@param line integer
---@param delta integer
---@return integer
local function start_row(rows, at, path, line, delta)
  local row = rows[at]
  if not path or (row and place_of(row) == ("%s:%d"):format(path, line)) then
    return at
  end
  local first, last, below, above
  for i, each in ipairs(rows) do
    if each.path == path and each.kind ~= "section" and each.kind ~= "comment" then
      first, last = first or i, i
      below = below or ((each.lnum or 1) > line and i or nil)
      above = (each.lnum or 1) < line and i or above
    end
  end
  if not first then
    return at
  end
  if delta > 0 then
    return below and below - 1 or last
  end
  return above and above + 1 or first
end

---Whether a step by each unit stops on a row that opens somewhere new.
---@type table<changeset.StepUnit, fun(row: changeset.Row): boolean>
local STOPS = {
  -- A deleted file's row and a whole file's review comment row open nowhere.
  change = function(row)
    return row.kind ~= "section" and not (row.kind == "file" and row.status == "deleted" or lists_file_comment(row))
  end,
  symbol = function(row)
    return row.kind == "symbol" and not row.ancestor
  end,
  file = function(row)
    return row.kind == "file" and row.status ~= "deleted"
  end,
}

---The row `count` places past `from` among `rows`, down for a positive `count`: each place a row `stops` takes that
---opens somewhere other than the last, starting from where the window it opens into stands. Stops at the last such row.
---@param rows changeset.Row[]
---@param from integer
---@param count integer
---@param here string? Where the window stands, as `place_of` spells it.
---@param stops fun(row: changeset.Row): boolean
---@return integer
local function placed(rows, from, count, here, stops)
  local delta = count > 0 and 1 or -1
  local to = from
  for _ = 1, math.abs(count) do
    local at = to + delta
    while rows[at] and not (stops(rows[at]) and place_of(rows[at]) ~= here) do
      at = at + delta
    end
    if not rows[at] then
      return to
    end
    to, here = at, place_of(rows[at])
  end
  return to
end

---Where `row` stands among `rows`, by id; 0 for none.
---@param rows changeset.Row[]
---@param row changeset.Row?
---@return integer
local function index_of(rows, row)
  for i, each in ipairs(rows) do
    if row and each.id == row.id then
      return i
    end
  end
  return 0
end

---Steps the sidebar's cursor `count` places by `unit`, then opens that row as `<CR>` does, without its review comment,
---in the window the sidebar opens changes in. A change is a row on screen; a symbol or a file is found whatever folds
---hide it, and unfolded. From a file window or the sidebar, focus stays there; from a window that holds no file, it
---goes where the row opened.
---@param count integer Down for positive.
---@param unit changeset.StepUnit
---@param hooks changeset.StepHooks
function M.open_step(count, unit, hooks)
  local state, lnum = sidebar_state.current(), cursor()
  if not (state and lnum) then
    return
  end
  local rows = unit == "change" and state.view:visible() or state.view:unfolded()
  local path, line = standing(state.tree.root)
  local from = start_row(rows, index_of(rows, state.view:row(lnum)), path, line, count > 0 and 1 or -1)
  local to = placed(rows, from, count, path and ("%s:%d"):format(path, line), STOPS[unit])
  if to == from then
    -- Not wrapped, so a run of `.` stops here rather than looping.
    return vim.api.nvim_echo({ { ("no %s %s"):format(count > 0 and "next" or "previous", unit) } }, false, {})
  end
  local focus = vim.api.nvim_get_current_win()
  if state.view:reveal(rows[to].id) then
    hooks.redraw()
  end
  move(index_of(state.view:visible(), rows[to]))
  local row = commit("reuse", hooks)
  if focus == window.win() and row then
    if hooks.back then
      hooks.back(row)
    end
    vim.api.nvim_set_current_win(focus)
  end
end

---Moves the sidebar's cursor `count` rows, skipping section headers, then previews the row it lands on.
---@param count integer Down for positive.
---@param preview fun() Preview the row under the sidebar's cursor.
function M.preview_step(count, preview)
  local state, lnum = sidebar_state.current(), cursor()
  if not (state and lnum) then
    return
  end
  for _ = 1, math.abs(count) do
    lnum = state.view:step(lnum, count > 0 and 1 or -1)
  end
  move(lnum)
  preview()
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

---Bind `keys` on the sidebar's buffer. `?` lists exactly these.
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
    jump("reuse", hooks)
  end, "Go to this change")
  -- The commit leaves the cursor in the window it jumped to, and `close` keeps
  -- focus where it already is, so the sidebar goes without taking the jump back.
  map(keys.jump_close, function()
    -- A whole file's review comment opens under its row, which closing would take away.
    if lists_file_comment(draw.row_at_cursor()) then
      return jump("reuse", hooks)
    end
    local row = commit("reuse", hooks)
    hooks.close()
    open_comment(row)
  end, "Go to this change and close the tree")
  map(keys.jump_vsplit, function()
    jump("vsplit", hooks)
  end, "Go to this change in a vertical split")
  map(keys.jump_split, function()
    jump("split", hooks)
  end, "Go to this change in a split")
  map(keys.jump_tab, function()
    jump("tab", hooks)
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
    help.show(buf, own)
  end, "Show these keymaps")
  map(keys.filter_kinds, function(state)
    open_kind_menu(state, redraw)
  end, "Filter by symbol kind")
  map(keys.filter, function(state)
    prompt_filter(state, redraw)
  end, "Filter the tree")
end

return M
