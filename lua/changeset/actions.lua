---What each sidebar key does, and the keymaps that bind them.
---The fold, step and filter keys ask the sidebar's view, then move the cursor or redraw; on a comment row the jump
---keys open what it lists, and the delete key deletes it.

local Paths = require("changeset.paths")
local build = require("changeset.build")
local draw = require("changeset.draw")
local help = require("changeset.help")
local icons = require("changeset.icons")
local review_comment = require("changeset.review_comment")
local reviewing = require("changeset.reviewing")
local sidebar_state = require("changeset.sidebar_state")
local unified_diff = require("changeset.unified_diff")
local view = require("changeset.view")
local viewed = require("changeset.viewed")
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
---@class changeset.StepHooks
---@field pick fun(row: changeset.Row) Mark `row` as the one last opened from the sidebar.
---@field back? fun(row: changeset.Row?) Told, before focus goes back to the sidebar, which row a step from it opened.
---@field redraw fun() Redraw the tree, once a step unfolds the rows over the one it reached.

---What a step counts as a place: any row that opens, or only a changed symbol's, or a file's.
---@alias changeset.StepUnit "change"|"symbol"|"file"

---@param lnum integer
local function move(lnum)
  vim.api.nvim_win_set_cursor(assert(window.win(), "changeset: sidebar is closed"), { lnum, 0 })
end

---@param how "reuse"|"vsplit"|"split"|"tab"
---@param hooks { pick: fun(row: changeset.Row) }
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
  if window.commit({ path = state.tree.root .. "/" .. row.path, lnum = row.lnum or 1, how = how }) then
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

---Whether `row` lists a review comment on lines of a file with unsaved edits, where opening it would land off its
---code; warns when so.
---@param row changeset.Row?
---@return boolean
local function refuses_unsaved(row)
  local comment = row and row.review_comment
  local tree = build.current()
  return comment ~= nil and comment.line ~= nil and tree ~= nil and reviewing.unsaved(tree.root, comment.path)
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
  if refuses_unsaved(row) then
    return
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
  local path = Paths.relative(root, name)
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
  if not (first and last) then
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
  local state, lnum = sidebar_state.current(), window.cursor()
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
  if state.view:reveal(assert(rows[to], "changeset: stepped past the rows").id) then
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
  local state, lnum = sidebar_state.current(), window.cursor()
  if not (state and lnum) then
    return
  end
  for _ = 1, math.abs(count) do
    lnum = state.view:step(lnum, count > 0 and 1 or -1)
  end
  move(lnum)
  preview()
end

---Moves the sidebar's cursor `count` rows, over every section header but a folded one.
---@param count integer Down for positive.
local function walk(count)
  local state, lnum = sidebar_state.current(), window.cursor()
  if not (state and lnum) then
    return
  end
  for _ = 1, math.abs(count) do
    lnum = state.view:walk(lnum, count > 0 and 1 or -1)
  end
  move(lnum)
end

---Scrolls the window previews go to `count` lines, down for positive, as `<C-e>` and `<C-y>` do there.
---@param count integer
local function scroll_preview(count)
  local win = window.peek_target()
  if win then
    vim.api.nvim_win_call(win, function()
      vim.cmd.normal({ math.abs(count) .. vim.keycode(count > 0 and "<C-e>" or "<C-y>"), bang = true })
    end)
  end
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

  local ok, typed = pcall(function()
    return vim.fn.input({
      prompt = "Filter changes: ",
      default = previous_query,
      cancelreturn = CANCELLED,
    })
  end)
  vim.api.nvim_del_augroup_by_id(group)

  state.view:narrow((ok and typed ~= CANCELLED) and typed or previous_query)
  redraw()
end

---The row to put the cursor on after marking `path` viewed from line `lnum` of `shown`: the next file row below that
---is not viewed and is not another copy of `path`, else `path`'s own row in the section `lnum` is in.
---@param shown changeset.Row[] The row on each line.
---@param lnum integer
---@param path string
---@param is_viewed fun(row: changeset.Row): boolean
---@return changeset.Row?
function M._after_viewing(shown, lnum, path, is_viewed)
  for i = lnum + 1, #shown do
    local row = shown[i]
    if row.kind == "file" and row.path ~= path and not is_viewed(row) then
      return row
    end
  end
  for i = lnum, 1, -1 do
    local row = assert(shown[i], "changeset: a line above the cursor without a row")
    if row.kind == "file" and row.path == path then
      return row
    end
  end
end

---Bind `keys` on the sidebar's buffer. `?` lists exactly these.
---@param buf integer
---@param keys changeset.Options.Keymaps
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

  ---Show `marks`, just written for `paths`, or report they could not be: unview `paths` when the mark of `path`, the
  ---cursor's file, no longer holds, else move the cursor past it.
  ---@param state changeset.SidebarState
  ---@param marks changeset.ViewedMarks?
  ---@param paths string[]
  ---@param path string?
  local function show_marks(state, marks, paths, path)
    if not marks then
      return vim.notify("Changeset: could not write " .. viewed.path(), vim.log.levels.ERROR)
    end
    state.marks = marks
    unified_diff.refresh_viewed()
    local file = path and vim.iter(state.tree.files):find(function(f)
      return f.path == path
    end)
    if not (file and viewed.holds(marks, file.path, file.digest)) then
      for _, p in ipairs(paths) do
        state.view:unview(state.rows, p)
      end
      return redraw()
    end
    local shown, lnum = state.view:visible(), assert(window.cursor(), "changeset: sidebar is closed")
    local target = M._after_viewing(shown, lnum, file.path, function(r)
      return viewed.holds(marks, r.path, r.digest)
    end)
    redraw()
    for at, r in ipairs(state.view:visible()) do
      if target and r.id == target.id then
        return move(at)
      end
    end
  end

  map(keys.jump, function()
    jump("reuse", hooks)
  end, "Go to this change")
  -- From another window, the first click only focused the sidebar, leaving its cursor off the row clicked.
  map(keys.jump and "<2-LeftMouse>", function()
    local pos = vim.fn.getmousepos()
    if pos.winid == window.win() and pos.line > 0 then
      move(pos.line)
      jump("reuse", hooks)
    end
  end, "Go to the change double-clicked")
  -- The commit leaves the cursor in the window it jumped to, and `close` keeps
  -- focus where it already is, so the sidebar goes without taking the jump back.
  map(keys.jump_close, function()
    -- A whole file's review comment opens under its row, which closing would take away.
    if lists_file_comment(draw.row_at_cursor()) then
      return jump("reuse", hooks)
    end
    if refuses_unsaved(draw.row_at_cursor()) then
      return
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
    local lnum = window.cursor()
    if lnum and state.view:open(lnum) then
      redraw()
    end
  end, "Expand")
  map(keys.collapse, function(state)
    local lnum = window.cursor()
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
    local lnum = window.cursor()
    if lnum then
      move(state.view:step_section(lnum, 1))
    end
  end, "Next section")
  map(keys.prev_section, function(state)
    local lnum = window.cursor()
    if lnum then
      move(state.view:step_section(lnum, -1))
    end
  end, "Previous section")
  -- Not `keymaps` options: they take the place of Neovim's own `j` and `k`.
  for _, lhs in ipairs({ "j", "<Down>" }) do
    set(lhs, function()
      walk(vim.v.count1)
    end, "Next row")
  end
  for _, lhs in ipairs({ "k", "<Up>" }) do
    set(lhs, function()
      walk(-vim.v.count1)
    end, "Previous row")
  end
  map(keys.scroll_preview_down, function()
    scroll_preview(vim.v.count1)
  end, "Scroll the preview down")
  map(keys.scroll_preview_up, function()
    scroll_preview(-vim.v.count1)
  end, "Scroll the preview up")
  map(keys.refresh, build.update, "Rebuild the tree")
  map(keys.yank, function()
    local row = draw.row_at_cursor()
    if not row or row.kind == "section" then
      return
    end
    local text = row.review_comment and review_comment.location(row.review_comment)
      or row.lnum and ("%s:%s"):format(row.path, row.lnum)
      or row.path
    Paths.copy(text, "relative path:line")
  end, "Yank path:line")
  map(keys.toggle_viewed, function(state)
    local row = draw.row_at_cursor()
    if not row or row.kind == "section" or row.kind == "comment" then
      return
    end
    local file = vim.iter(state.tree.files):find(function(f)
      return f.path == row.path
    end)
    if not file then
      return
    end
    show_marks(state, viewed.toggle(viewed.path(), state.tree.root, file.path, file.digest), { file.path }, file.path)
  end, "Mark the file viewed, or not")
  map(keys.toggle_viewed_all, function(state)
    local row = draw.row_at_cursor()
    local files = state.tree.files
    local paths = vim.tbl_map(function(f)
      return f.path
    end, files)
    show_marks(state, viewed.toggle_all(viewed.path(), state.tree.root, files), paths, row and row.path)
  end, "Mark every file viewed, or none")
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
