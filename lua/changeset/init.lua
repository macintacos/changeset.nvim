---A read-only sidebar mapping what this branch changed, nested by symbol.
---
---See doc/agents/design.md for the design. This file is the public API and the window
---state machine: `build` keeps the tree, `sidebar_state` the sidebar's own table for it,
---`view` holds its folds and narrowing, `draw` puts it on the sidebar's buffer, `position`
---says where the user stands in it, and what each key does is `actions`. The thinking
---happens in the pure modules they call.

local actions = require("changeset.actions")
local buffers = require("changeset.buffers")
local build = require("changeset.build")
local comment_store = require("changeset.comment_store")
local config = require("changeset.config")
local diff = require("changeset.diff")
local draw = require("changeset.draw")
local highlights = require("changeset.highlights")
local Paths = require("changeset.paths")
local render = require("changeset.render")
local Rows = require("changeset.rows")
local sidebar_state = require("changeset.sidebar_state")
local view = require("changeset.view")
local window = require("changeset.window")

-- How long a picker's first ask blocks on the diff before giving up on it.
local DIFF_WAIT_MS = 2000

-- Capitalised: `:mksession` saves only globals named so, and only with "globals" in 'sessionoptions'.
local POSITION_GLOBAL = "ChangesetPosition"

local M = {}

local augroup = vim.api.nvim_create_augroup("changeset", { clear = true })

---Whether a `track` is already scheduled for this tick.
---@type boolean
local tracking = false

---Whether the window last left was a float: coming back from one is not arriving.
---@type boolean
local left_float = false

---The keys the open sidebar bound, which its footer and preview band name.
---@type changeset.Config.Keymaps
local bound_keys = {}

---The width of the sidebar's window when the tree was last drawn.
---@type integer?
local drawn_width

---Draw the tree, naming the keys the sidebar bound.
local function redraw()
  local win = window.win()
  drawn_width = win and vim.api.nvim_win_get_width(win)
  draw.draw(bound_keys.filter_kinds)
end

---The row a step from the sidebar just opened, which its next `CursorMoved` mustn't preview over the opened line.
---@type string?
local opened_id

---Whether the sidebar's next `WinEnter` is a step handing focus back, which mustn't land on your row and undo it.
local stepping_back = false

local DELETED = "This file was deleted on this branch"

local NO_BASE = "no merge base with the default branch"

-- snacks.nvim's bigfile size: past it a buffer's synchronous treesitter parse takes noticeable time, on every pass
-- over the row.
local PREVIEW_MAX_BYTES = 1.5 * 1024 * 1024

---Preview what `row`'s file held at `tree`'s base before the branch deleted it, else the notice that it was deleted.
---git answers later, by when the cursor may have left the row, or you the window you asked from; either then previews
---nothing, rather than swap the buffer of a window you have since entered.
---@param tree changeset.Tree
---@param row changeset.Row
local function preview_deleted(tree, row)
  local band = draw.band_for(row, bound_keys.jump)
  local from = vim.api.nvim_get_current_win()
  diff.blob(tree.base .. ":" .. row.path, tree.root, function(text)
    local still = draw.row_at_cursor()
    if not (still and still.id == row.id and vim.api.nvim_get_current_win() == from) then
      return
    end
    -- A NUL is git's own test for a binary file.
    if text and #text <= PREVIEW_MAX_BYTES and not text:find("\0", 1, true) then
      window.preview_deleted(row.path, text, band)
    else
      window.preview_notice(DELETED, band)
    end
  end)
end

local UNPREVIEWABLE = "This file is binary or too big to preview"

---Whether the file at `path` is small enough to preview, and text by git's test: no NUL in its first 8000 bytes.
---@param path string
---@return boolean
local function previewable(path)
  if vim.fn.getfsize(path) > PREVIEW_MAX_BYTES then
    return false
  end
  local file = io.open(path, "rb")
  if not file then
    return true
  end
  local head = file:read(8000) or ""
  file:close()
  return not head:find("\0", 1, true)
end

local function preview_current()
  local state = sidebar_state.current()
  local row = draw.row_at_cursor()
  local opened = opened_id
  opened_id = nil
  if not row or row.id == opened then
    return
  end
  assert(state, "changeset: no tree built yet")
  if row.kind == "file" and row.status == "deleted" then
    preview_deleted(state.tree, row)
  elseif not (row.kind == "comment" or row.lnum or row.kind == "file") then
    return
  elseif vim.fn.filereadable(state.tree.root .. "/" .. row.path) == 0 then
    window.preview_notice(DELETED, draw.band_for(row, bound_keys.jump))
  elseif not previewable(state.tree.root .. "/" .. row.path) then
    window.preview_notice(UNPREVIEWABLE, draw.band_for(row, bound_keys.jump))
  else
    window.preview(
      state.tree.root .. "/" .. row.path,
      row.lnum or row.kind == "file" and 1 or nil,
      draw.band_for(row, bound_keys.jump),
      { row = row, state = state }
    )
  end
end

local PASSING_BUFTYPES = { terminal = true, help = true }

---Note the file and line the cursor is in. The sidebar, floats, terminals and help
---are not somewhere the user is, so they leave the last place standing.
local function track()
  local state = sidebar_state.current()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  if
    not state
    or win == window.win()
    or vim.api.nvim_win_get_config(win).relative ~= ""
    or PASSING_BUFTYPES[vim.bo[buf].buftype]
  then
    return
  end
  local name = vim.api.nvim_buf_get_name(buf)
  local path = Paths.relative(state.tree.root, name)
  state.position:track(path and { path = path, lnum = vim.api.nvim_win_get_cursor(win)[1] } or nil)
  draw.paint()
end

---Keep where you are and the sidebar's cursor row and scroll in a global `:mksession`
---saves, so every session write carries them without work of its own at write time.
local function remember()
  local state = sidebar_state.current()
  local win = window.win()
  local offset = win and vim.api.nvim_win_get_cursor(win)[1] - vim.fn.line("w0", win)
  local saved = state and state.position:saved(draw.row_at_cursor(), offset)
  if saved then
    vim.g[POSITION_GLOBAL] = vim.json.encode(saved)
  end
end

---Put the sidebar's cursor on the line `position` chose, when it chose one, with `offset` lines above it on screen
---when it chose that too, and repaint the row marks.
---@param lnum integer?
---@param offset integer?
local function apply(lnum, offset)
  local win = window.win()
  if lnum and win then
    vim.api.nvim_win_set_cursor(win, { lnum, 0 })
    if offset then
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview({ topline = math.max(1, lnum - offset) })
      end)
    end
  end
  draw.paint()
end

---Make `row` the one last opened.
---@param row changeset.Row
local function pick(row)
  local state = sidebar_state.current()
  assert(state, "changeset: no tree built yet")
  state.position:pick(row)
  draw.paint()
end

---What captions orphan hunks in one rebuild, looking loaded buffers up once.
---
---Prefers the buffer, which holds unwritten changes the file does not. Reading
---symbols is what loads a file, so a file answered from the cache has no buffer
---and is read from disk instead.
---@param root string
---@return changeset.rows.Lines lines Its `text` and `tick`.
local function captions(root)
  local index = buffers.index()
  return {
    text = function(path, lnum)
      if lnum < 1 then
        return nil
      end
      local full = root .. "/" .. path
      local buf = index[vim.fs.normalize(full)]
      if buf then
        return vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1]
      end
      local ok, lines = pcall(vim.fn.readfile, full, "", lnum)
      return ok and lines[lnum] or nil
    end,
    tick = function(path)
      local buf = index[vim.fs.normalize(root .. "/" .. path)]
      return buf and vim.api.nvim_buf_get_changedtick(buf)
    end,
  }
end

---Whether the tree is done growing under `path`: its diff is in, and so are its
---symbols unless the diff does not hold it.
---@param path string
---@return boolean
local function decided(path)
  local tree = build.current()
  assert(tree, "changeset: no tree built yet")
  if not tree.collected then
    return false
  end
  return not vim.iter(tree.files):any(function(file)
    return file.path == path and Rows.read_status(file, tree.symbols) == "reading"
  end)
end

local function rebuild()
  local state = sidebar_state.current()
  assert(state, "changeset: no tree built yet")
  -- Taken before the rows change: whether the cursor moved is judged by the row it was on.
  local before = (draw.row_at_cursor() or {}).id
  local lines = captions(state.tree.root)
  lines.comments = state.tree.comments
  state.rows = Rows.build(state.tree.files, state.tree.symbols, lines)
  redraw()
  apply(state.position:rebuilt(draw.view(), before, decided))
end

---A step pressed before the tree was ready, with the window and buffer it was pressed in.
---@class changeset.WaitingStep
---@field count integer Presses added up, down for positive.
---@field kind changeset.StepUnit|"preview" What the presses step by; a press of another kind starts the count again.
---@field take fun(count: integer)
---@field win integer
---@field buf integer

---@type changeset.WaitingStep?
local waiting

---What a step from `M.step` lends `actions.open_step`.
---@type changeset.StepHooks
local step_hooks = {
  pick = pick,
  redraw = redraw,
  back = function(row)
    opened_id = row and row.id
    stepping_back = true
  end,
}

---Whether a step can be taken: the diff is read, and so are the symbols of the file the step would start from, or
---its rows would be the placeholders drawn while they're read.
---@param tree changeset.Tree
---@return boolean
local function ready(tree)
  if not tree.collected then
    return false
  end
  local win = window.peek_target()
  local name = win and vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) or ""
  local path = Paths.relative(tree.root, name)
  return not path or decided(path)
end

---Take the waiting step once the tree is ready, if you're still where you pressed it; else drop it unsaid.
local function take_waiting()
  local tree = build.current()
  if not (waiting and tree and ready(tree)) then
    return
  end
  local step = waiting
  waiting = nil
  if
    step.count == 0
    or vim.api.nvim_get_current_win() ~= step.win
    or vim.api.nvim_win_get_buf(step.win) ~= step.buf
  then
    return
  end
  local state = assert(sidebar_state.current(), "changeset: no tree built yet")
  -- Landed again: the rows the sidebar opened on held no row for where you are.
  apply(state.position:entered(draw.view()))
  step.take(step.count)
end

---What the sidebar does as the tree changes.
---@type table<changeset.TreeEvent, fun()>
local on_tree_event = {
  diff = function()
    rebuild()
    take_waiting()
  end,
  symbols = function()
    rebuild()
    take_waiting()
  end,
  pr = redraw,
  failed = function()
    waiting = nil
    assert(sidebar_state.current(), "changeset: no tree built yet").position:failed()
  end,
}

-- Fires: the tree reading its diff or a file's symbols, its PR changing, or its diff failing to read.
build.subscribe(function(event)
  on_tree_event[event]()
end)

-- Fires: a review comment kept, dropped or cleared, so the Comments section follows it.
comment_store.subscribe(redraw)

-- Loaded here so that using changeset at all draws the marks.
local review_comments = require("changeset.review_comments")

---The sidebar's footer, which its statusline evaluates on every redraw.
---@return string
function M.footer()
  local state = sidebar_state.current()
  local lnum = window.cursor()
  if not (state and lnum) then
    return ""
  end
  local file, files = view.position(state.view:visible(), lnum)
  return render.footer({ file = file, files = files, query = state.view:query(), keys = bound_keys })
end

---Public API: the file rows under the sidebar's sections, less the kinds it hides, for the current buffer's repository.
---
---The first call builds and keeps the tree, loading the changed files and their language servers, and
---blocks up to `DIFF_WAIT_MS` (2 s) while the diff is read. `rows` are the file rows, uncompressed, with
---their symbols under `children`.
---@return { rows: changeset.Row[], root: string, ref: string }? tree
---@return string? err Why there is no tree yet.
function M.rows()
  if not build.build() then
    return nil, NO_BASE
  end
  -- The first ask builds the tree too, and a picker cannot fill in behind it the way the sidebar does.
  vim.wait(DIFF_WAIT_MS, function()
    local tree = build.current()
    return not tree or tree.collected
  end, 10)
  local state = sidebar_state.current()
  if not (state and state.tree.collected) then
    return nil, "still reading the diff"
  end
  -- A tree whose diff landed before the sidebar loaded announced nothing the sidebar heard.
  if #state.rows == 0 then
    rebuild()
  end
  return {
    rows = view.by_kind(Rows.files(state.rows), state.view:hidden()),
    root = state.tree.root,
    ref = state.tree.ref,
  }
end

---Public API: the comment bubble on line `lnum` of `buf` and its highlight group, for a `'statuscolumn'` to draw;
---nil on a line without one. Answers from the buffer's marks alone, so it is cheap on every screen row, whatever
---`review_comment.sign` is.
---@param buf integer
---@param lnum integer 1-based, as `v:lnum`.
---@return string? glyph `󰍩`, or `󰍪` for a draft.
---@return string? hl `ChangesetReviewComment`, or `ChangesetReviewCommentDraft` for a draft.
function M.bubble(buf, lnum)
  return review_comments.bubble(buf, lnum)
end

---Configure changeset. Optional; reaches the sidebar the next time it opens; PR Review Mode, once on, stays on.
---See `changeset.Config`.
---@param opts changeset.Config?
function M.setup(opts)
  config.setup(opts)
  -- The marks drew before setup(), to the defaults.
  review_comments.redraw()
  if config.get().pr_review.enabled then
    require("changeset.review").activate()
  end
end

---Drop everything the sidebar set up but its window.
local function release()
  waiting = nil
  opened_id, stepping_back = nil, false
  require("changeset.menu").close()
  vim.api.nvim_clear_autocmds({ group = augroup })
end

---Builds the tree for the current buffer's repository, unless it is already built there, warning when it can't.
---@return boolean ready
local function built()
  if not build.build() then
    vim.notify("Changeset: " .. NO_BASE, vim.log.levels.WARN)
    return false
  end
  -- The cursor is still where the user was, and nothing tracked it before a tree existed.
  track()
  return true
end

---Rebuild the tree now, or build the current buffer's repository's when there is none.
function M.refresh()
  if build.current() then
    build.update()
  else
    built()
  end
end

---Open the sidebar on the current buffer's repository, drawing its tree.
function M.open()
  -- `window.buf()`, not `window.win()`: the buffer is wiped with its window, so it is
  -- live exactly while a sidebar stands on some tabpage.
  if window.buf() then
    M.close()
  else
    -- A session read over the sidebar closes its window, and this runs before the
    -- `WinClosed` close that would let go of it.
    release()
  end
  local kept = build.current()
  if not built() then
    return
  end
  bound_keys = config.get().keymaps

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  -- Wiped with its window. A scratch buffer is kept otherwise, so every close would
  -- leave one behind, its extmarks and mappings included.
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  -- The tree draws its own guides; a scope line would be a second set.
  vim.b[buf].miniindentscope_disable = true
  -- The hidden cursor would still underline whatever word a click leaves it on.
  vim.b[buf].minicursorword_disable = true

  highlights.define_highlights()
  local win = window.open(buf)
  vim.wo[win].statusline = "%{%v:lua.require'changeset'.footer()%}"
  -- In its window, so a `FileType` handler's window options land on the sidebar's, after its own.
  vim.bo[buf].filetype = "changeset"
  -- After `filetype`, so these replace any `]]`/`[[` a plugin maps on the buffer at `FileType`.
  actions.set_keymaps(buf, bound_keys, { pick = pick, close = M.close })

  -- Fires: the sidebar's window going without the plugin being asked — `:q`, `:only`,
  -- `:tabclose`, a layout plugin. Scheduled because the window is still in the layout
  -- while this runs, and `close` reads the layout to decide where to leave the cursor.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    pattern = tostring(win),
    desc = "changeset: let go of the sidebar when its window closes another way",
    callback = function()
      vim.schedule(function()
        -- A session read over the sidebar opens its own before this runs.
        if not window.is_visible() then
          M.close()
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    buffer = buf,
    desc = "changeset: preview the row under the cursor without leaving the sidebar",
    callback = preview_current,
  })
  -- Fires: the sidebar's cursor moving. The selected row is the cursor's own marker,
  -- the terminal's being hidden here, so it moves in step rather than a tick behind.
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    buffer = buf,
    desc = "changeset: move the selected row with the cursor",
    callback = function()
      draw.paint()
    end,
  })
  -- Fires: the sidebar scrolling, by any means. Back at the top, the header's totals
  -- stay out of view unless they are scrolled in again. Only on the way up: scrolling
  -- down from the top starts by taking them away, and restoring them would pin the tree.
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = augroup,
    pattern = tostring(win),
    desc = "changeset: keep the header's totals in view at the top of the tree",
    callback = function()
      if vim.v.event[tostring(win)].topline < 0 then
        draw.reveal_header(win)
      end
    end,
  })
  -- Fires: the editor being resized. Moves the tree below the files when the editor
  -- gets too narrow to keep it beside them, and back once it is wide enough; redrawn
  -- either way, since rows are trimmed to the window's width. An open kind menu docks
  -- against the sidebar where it now stands.
  vim.api.nvim_create_autocmd("VimResized", {
    group = augroup,
    desc = "changeset: move the tree beside or below the files as the editor's width allows",
    callback = function()
      window.relayout()
      redraw()
      require("changeset.menu").relayout()
    end,
  })
  -- Fires: windows changing size. The sidebar's own, dragged or `:resize`d, needs its rows refitted to the width,
  -- which `winfixwidth` doesn't stop.
  vim.api.nvim_create_autocmd("WinResized", {
    group = augroup,
    desc = "changeset: refit the tree to its window's new width",
    callback = function()
      local sidebar = window.win()
      if sidebar and vim.api.nvim_win_get_width(sidebar) ~= drawn_width then
        redraw()
      end
    end,
  })
  -- Fires: entering a tabpage. A sidebar standing in it missed every redraw made while it was in another.
  vim.api.nvim_create_autocmd("TabEnter", {
    group = augroup,
    desc = "changeset: redraw the tree missed while the sidebar stood in another tabpage",
    callback = function()
      local state = sidebar_state.current()
      if not (state and window.is_visible()) then
        return
      end
      local before = (draw.row_at_cursor() or {}).id
      redraw()
      apply(state.position:rebuilt(draw.view(), before, decided))
    end,
  })
  -- Fires: leaving any window while the sidebar is open. Remembers whether it was a
  -- float, so the sidebar's `WinEnter` can tell a return from one from an arrival.
  vim.api.nvim_create_autocmd("WinLeave", {
    group = augroup,
    desc = "changeset: note whether the window being left is a float",
    callback = function()
      left_float = vim.api.nvim_win_get_config(0).relative ~= ""
    end,
  })
  -- Fires: the cursor entering the sidebar by any route — `:Changeset`, a click,
  -- `<C-w>` — but not a return from a float such as the kind menu, which the user
  -- never left the sidebar for. Lands on the row you are on, dropping a restored row
  -- still waiting; the `CursorMoved` that follows previews it.
  vim.api.nvim_create_autocmd("WinEnter", {
    group = augroup,
    buffer = buf,
    desc = "changeset: put the sidebar's cursor on the row you are on",
    callback = function()
      local state = sidebar_state.current()
      local back = stepping_back
      stepping_back = false
      if state and vim.api.nvim_get_current_win() == window.win() and not left_float and not back then
        apply(state.position:entered(draw.view()))
      end
    end,
  })
  -- Fires: the cursor entering any window while the sidebar is open. Nested so the
  -- buffer swaps inside the commit fire their autocmds as `<CR>`'s do.
  vim.api.nvim_create_autocmd("WinEnter", {
    group = augroup,
    nested = true,
    desc = "changeset: open a previewed file once the cursor enters its window",
    callback = function()
      local claimed = window.claim()
      -- A build for another repository, base or branch replaces the tree, and so the
      -- sidebar's state, under a preview.
      if claimed and claimed.state == sidebar_state.current() then
        pick(claimed.row)
      end
    end,
  })
  -- Fires: the cursor entering any window while the sidebar is open, so the cursor
  -- hides and the selected row appears on arriving in the sidebar, and both undo on
  -- leaving it, for a float opened from it too.
  vim.api.nvim_create_autocmd("WinEnter", {
    group = augroup,
    desc = "changeset: stand the selected row in for the cursor while it is in the sidebar",
    callback = function()
      window.sync_cursor()
      draw.paint()
    end,
  })
  require("changeset.unified_diff").activate()

  redraw()
  -- A kept tree misses what nothing announced, such as a file edited outside Neovim while it kept focus.
  if build.current() == kept then
    build.refresh()
  end
end

---Dismiss the sidebar. The tree stays, and keeps refreshing.
function M.close()
  release()
  window.close()
end

---Fill `placeholder`, in the current tabpage, with the tree, or let go of it when there is no tree to fill it with.
---@param placeholder integer
local function fill(placeholder)
  M.open()
  if not window.is_visible() then
    local stale = vim.api.nvim_win_get_buf(placeholder)
    if #vim.api.nvim_tabpage_list_wins(0) > 1 then
      vim.api.nvim_win_close(placeholder, true)
    else
      vim.api.nvim_win_call(placeholder, vim.cmd.enew)
    end
    -- A session lists it, under a name nothing else answers to.
    pcall(vim.api.nvim_buf_delete, stale, { force = true })
    return
  end
  local state = sidebar_state.current()
  assert(state, "changeset: no tree built yet")
  local ok, recorded = pcall(vim.json.decode, vim.g[POSITION_GLOBAL])
  apply(state.position:restore(ok and recorded or nil, draw.view(), decided))
end

---Fill the window a restored session left standing where the sidebar was, and bring
---back where you were and the sidebar's cursor row once the tree holds them.
---
---A session records the layout but not a scratch buffer's contents, so the
---sidebar comes back empty. Filling that window is also what keeps the next
---`toggle()` from opening a second one beside it.
function M.restore()
  local placeholder = window.placeholder()
  if not placeholder then
    return
  end
  -- The sidebar opens in the tabpage it is called from, which the session may not have left focused.
  local here = vim.api.nvim_get_current_tabpage()
  vim.api.nvim_set_current_tabpage(vim.api.nvim_win_get_tabpage(placeholder))
  fill(placeholder)
  if vim.api.nvim_tabpage_is_valid(here) then
    vim.api.nvim_set_current_tabpage(here)
  end
end

---What `toggle()` does next, given where the sidebar and the cursor are.
---@param st { visible: boolean, focused: boolean }
---@return "open"|"focus"|"close"
local function next_action(st)
  if not st.visible then
    return "open"
  end
  return st.focused and "close" or "focus"
end

---Takes a step of `kind` in the sidebar, opening a closed one first, unfocused, on the row for where you are. Presses
---made before the tree is ready add up, and are taken once it is.
---@param count integer Down for positive.
---@param kind changeset.StepUnit|"preview"
---@param take fun(count: integer)
local function walk(count, kind, take)
  if not window.is_visible() then
    M.open()
    if not window.is_visible() then
      return
    end
    local state = assert(sidebar_state.current(), "changeset: no tree built yet")
    apply(state.position:entered(draw.view()))
  end
  local tree = build.current()
  if not (tree and ready(tree)) then
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local before = waiting and waiting.win == win and waiting.buf == buf and waiting.kind == kind and waiting.count or 0
    waiting = { count = before + count, kind = kind, take = take, win = win, buf = buf }
    return vim.api.nvim_echo({ { "reading the changes…" } }, false, {})
  end
  take(count)
end

---Steps the sidebar's selected row `count` places and opens it in the window you are editing in. From a file window
---or the sidebar, focus stays there. A closed sidebar opens first, unfocused, on the row for where you are. Presses
---made before the tree is ready add up, and are taken once it is.
---@param count integer Down for positive.
---@param unit ("symbol"|"file")? What counts as a place: a changed symbol, or a file, whatever folds hide it. Any row
---on screen that opens, without one.
function M.step(count, unit)
  local by = unit or "change"
  walk(count, by, function(n)
    actions.open_step(n, by, step_hooks)
  end)
end

---Moves the sidebar's selected row `count` rows, past section headers, and previews it in the window you were last
---in without opening it. A closed sidebar opens first, unfocused, on the row for where you are. Presses made before
---the tree is ready add up, and are taken once it is.
---@param count integer Down for positive.
function M.preview_step(count)
  walk(count, "preview", function(n)
    actions.preview_step(n, preview_current)
  end)
end

---Open, focus, or dismiss the sidebar, depending on where the cursor is.
function M.toggle()
  local action = next_action({ visible = window.is_visible(), focused = window.is_focused() })
  if action == "open" then
    M.open()
    window.focus()
  elseif action == "focus" then
    window.focus()
  else
    M.close()
  end
end

-- Fires: every buffer or window switch, cursor move and scroll, sidebar open or not,
-- so "you are here" is current whenever the sidebar shows, and the sidebar's scroll
-- whenever a session is written. Scheduled because a preview swaps its buffer inside
-- `nvim_win_call`, which fires these with the borrowed window current; by the next
-- tick focus is back where the user is.
vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "CursorMoved", "CursorMovedI", "WinScrolled" }, {
  group = vim.api.nvim_create_augroup("changeset.track", { clear = true }),
  desc = "changeset: track the file and line the cursor is in",
  callback = function()
    if build.current() and not tracking then
      tracking = true
      vim.schedule(function()
        tracking = false
        track()
        remember()
      end)
    end
  end,
})

-- Fires: the cursor entering any window, or any window taking a buffer, sidebar
-- open or not — the two ways a preview band can come to sit where the user reads.
vim.api.nvim_create_autocmd({ "WinEnter", "BufWinEnter" }, {
  group = vim.api.nvim_create_augroup("changeset.unband", { clear = true }),
  desc = "changeset: keep the preview band off the window the cursor is in",
  callback = window.unband,
})

-- Fires: a session starting to load. It lays its windows out from the focused one, and
-- the sidebar's would take a file with the sidebar's window options still on it.
vim.api.nvim_create_autocmd("SessionLoadPre", {
  group = vim.api.nvim_create_augroup("changeset.session", { clear = true }),
  desc = "changeset: close the sidebar before a session lays out its windows",
  callback = function()
    if window.buf() then
      M.close()
    end
  end,
})

return M
