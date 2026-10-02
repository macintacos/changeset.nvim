---A read-only sidebar mapping what this branch changed, nested by symbol.
---
---See doc/agents/design.md for the design. This file is the public API and the window state
---machine: `build` keeps the tree, `view` holds its folds and narrowing, `draw` puts it on
---the sidebar's buffer, `position` says where the user stands in it, and what each key does
---is `actions`. The thinking happens in the pure modules they call.

local actions = require("changeset.actions")
local build = require("changeset.build")
local config = require("changeset.config")
local draw = require("changeset.draw")
local position = require("changeset.position")
local prefs = require("changeset.prefs")
local render = require("changeset.render")
local tree = require("changeset.tree")
local view = require("changeset.view")
local window = require("changeset.window")

-- How long a picker's first ask blocks on the diff before giving up on it.
local DIFF_WAIT_MS = 2000

-- Capitalised: `:mksession` saves only globals named so, and only with "globals" in 'sessionoptions'.
local POSITION_GLOBAL = "ChangesetPosition"

local M = {}

local augroup = vim.api.nvim_create_augroup("changeset", { clear = true })

---@class changeset.Session: changeset.Tree
---@field file string Preferences file for this changeset session.
---@field rows changeset.Row[]
---@field view changeset.View What the sidebar shows of the tree.
---@field position changeset.Position Where the user stands in this tree.

---Whether a `track` is already scheduled for this tick.
---@type boolean
local tracking = false

---Whether the window last left was a float: coming back from one is not arriving.
---@type boolean
local left_float = false

---The keys the open sidebar bound, which its footer and preview band name.
---@type changeset.Config.Keymaps
local bound_keys = {}

---Draw the tree, naming the keys the sidebar bound.
local function redraw()
  draw.draw(bound_keys.filter_kinds)
end

local function preview_current()
  local session = build.current()
  local row = draw.row_at_cursor()
  if not row then
    return
  end
  assert(session, "changeset: no open session")
  if row.lnum and row.kind ~= "file" then
    window.preview(
      session.root .. "/" .. row.path,
      row.lnum,
      draw.band_for(row, bound_keys.jump),
      { row = row, session = session }
    )
  elseif row.kind == "file" and row.status == "deleted" then
    window.preview_notice("This file was deleted on this branch", draw.band_for(row, bound_keys.jump))
  elseif row.kind == "file" then
    window.preview(
      session.root .. "/" .. row.path,
      1,
      draw.band_for(row, bound_keys.jump),
      { row = row, session = session }
    )
  end
end

local PASSING_BUFTYPES = { terminal = true, help = true }

---Note the file and line the cursor is in. The sidebar, floats, terminals and help
---are not somewhere the user is, so they leave the last place standing.
local function track()
  local session = build.current()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  if
    not session
    or win == window.win()
    or vim.api.nvim_win_get_config(win).relative ~= ""
    or PASSING_BUFTYPES[vim.bo[buf].buftype]
  then
    return
  end
  local name = vim.api.nvim_buf_get_name(buf)
  local path = name ~= "" and vim.fs.relpath(session.root, vim.fs.normalize(name)) or nil
  session.position:track(path and { path = path, lnum = vim.api.nvim_win_get_cursor(win)[1] } or nil)
  draw.paint()
end

---Keep where you are and the sidebar's cursor row in a global `:mksession` saves, so
---every session write carries them without work of its own at write time.
local function remember()
  local session = build.current()
  local saved = session and session.position:saved(draw.row_at_cursor())
  if saved then
    vim.g[POSITION_GLOBAL] = vim.json.encode(saved)
  end
end

---Put the sidebar's cursor on the line `position` chose, when it chose one, and repaint the row marks.
---@param lnum integer?
local function apply(lnum)
  local win = window.win()
  if lnum and win then
    vim.api.nvim_win_set_cursor(win, { lnum, 0 })
  end
  draw.paint()
end

---Make `row` the one last opened.
---@param row changeset.Row
local function pick(row)
  local session = build.current()
  assert(session, "changeset: no open session")
  session.position:pick(row)
  draw.paint()
end

---Text of a changed line, for captioning an orphan hunk.
---
---Prefers the buffer, which holds unwritten changes the file does not. Reading
---symbols is what loads a file, so a file answered from the cache has no buffer
---and is read from disk instead.
---@param path string
---@param lnum integer
---@return string?
local function line_text(path, lnum)
  local session = build.current()
  if lnum < 1 then
    return nil
  end
  assert(session, "changeset: no open session")
  local full = session.root .. "/" .. path
  local buf = vim.fn.bufnr(full)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    return vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1]
  end
  local ok, lines = pcall(vim.fn.readfile, full, "", lnum)
  return ok and lines[lnum] or nil
end

---Whether the tree is done growing under `path`: its diff is in, and so are its
---symbols unless the diff does not hold it.
---@param path string
---@return boolean
local function decided(path)
  local session = build.current()
  assert(session, "changeset: no open session")
  if not session.collected then
    return false
  end
  return not vim.iter(session.files):any(function(file)
    return file.path == path and tree.read_status(file, session.symbols) == "reading"
  end)
end

local function rebuild()
  local session = build.current()
  assert(session, "changeset: no open session")
  -- Taken before the rows change: whether the cursor moved is judged by the row it was on.
  local before = (draw.row_at_cursor() or {}).id
  session.rows = tree.build(session.files, session.symbols, { text = line_text, comments = session.comments })
  redraw()
  apply(session.position:rebuilt(draw.view(), before, decided))
end

build.attach({
  view = function(root, branch)
    local preferences_file = prefs.path()
    return {
      file = preferences_file,
      rows = {},
      view = view.for_root(root, prefs.resolve(prefs.load(preferences_file), root, branch)),
      position = position.new(),
    }
  end,
})

-- Fires: the tree reading its diff or a file's symbols, its PR changing, or its diff failing to read.
build.subscribe(function(event, session)
  if event == "diff" or event == "symbols" then
    rebuild()
  elseif event == "pr" then
    redraw()
  else
    session --[[@as changeset.Session]].position:failed()
  end
end)

-- The pipeline lives in `build`; these stay on `require("changeset")` for the plugin, `pick` and the specs.
M.build = build.build
M.refresh = build.refresh

---The sidebar's footer, which its statusline evaluates on every redraw.
---@return string
function M.footer()
  local session = build.current()
  local win = window.win()
  if not (session and win) then
    return ""
  end
  local file, files = view.position(session.view:visible(), vim.api.nvim_win_get_cursor(win)[1])
  return render.footer({ file = file, files = files, query = session.view:query(), keys = bound_keys })
end

---Public API: the file rows under the sidebar's sections, less the kinds it hides, for the current buffer's repository.
---
---The first call builds and keeps the tree, loading the changed files and their language servers, and
---blocks up to `DIFF_WAIT_MS` (2 s) while the diff is read. `rows` are the file rows, uncompressed, with
---their symbols under `children`.
---@return { rows: changeset.Row[], root: string, ref: string }? tree
---@return string? err Why there is no tree yet.
function M.rows()
  if not M.build() then
    return nil, "no merge base with the default branch"
  end
  -- The first ask builds the tree too, and a picker cannot fill in behind it the way the sidebar does.
  vim.wait(DIFF_WAIT_MS, function()
    local session = build.current()
    return not session or session.collected
  end, 10)
  local session = build.current()
  if not (session and session.collected) then
    return nil, "still reading the diff"
  end
  return { rows = view.by_kind(tree.files(session.rows), session.view:hidden()), root = session.root, ref = session.ref }
end

---The tree, for specs.
---@return changeset.Session?
function M._tree()
  return build.current()
end

---Configure changeset. Optional; reaches the sidebar the next time it opens; PR Review Mode, once on, stays on.
---See `changeset.Config`.
---@param opts changeset.Config?
function M.setup(opts)
  config.setup(opts)
  if config.get().pr_review.enabled then
    require("changeset.review").activate()
  end
end

---Open the sidebar on the current buffer's repository, drawing its tree.
function M.open()
  -- `window.buf()`, not `window.win()`: the buffer is wiped with its window, so it is
  -- live exactly while a sidebar stands on some tabpage.
  if window.buf() then
    M.close()
  end
  local kept = build.current()
  if not M.build() then
    return vim.notify("Changeset: no merge base with the default branch", vim.log.levels.WARN)
  end
  bound_keys = config.get().keymaps

  -- The cursor is still where the user was, and nothing tracked it before a tree existed.
  track()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "changeset"
  vim.bo[buf].buftype = "nofile"
  -- Wiped with its window. A scratch buffer is kept otherwise, so every close would
  -- leave one behind, its extmarks and mappings included.
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  -- The tree draws its own guides; a scope line would be a second set.
  vim.b[buf].miniindentscope_disable = true
  -- The hidden cursor would still underline whatever word a click leaves it on.
  vim.b[buf].minicursorword_disable = true

  render.define_highlights()
  local win = window.open(buf)
  vim.wo[win].statusline = "%{%v:lua.require'changeset'.footer()%}"
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
      vim.schedule(M.close)
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
  -- either way, since rows are trimmed to the window's width.
  vim.api.nvim_create_autocmd("VimResized", {
    group = augroup,
    desc = "changeset: move the tree beside or below the files as the editor's width allows",
    callback = function()
      window.relayout()
      redraw()
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
      local session = build.current()
      if session and vim.api.nvim_get_current_win() == window.win() and not left_float then
        apply(session.position:entered(draw.view()))
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
      -- A build for another repository, base or branch replaces the session under a preview.
      if claimed and claimed.session == build.current() then
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
  actions.bind_step_keys(bound_keys, preview_current)

  redraw()
  -- A kept tree misses what nothing announced, such as a file edited outside Neovim while it kept focus.
  if build.current() == kept then
    M.refresh()
  end
end

---Dismiss the sidebar and its step keys, putting back what they replaced. The tree stays, and keeps refreshing.
function M.close()
  require("changeset.menu").close()
  actions.unbind_step_keys()
  vim.api.nvim_clear_autocmds({ group = augroup })
  window.close()
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
  M.open()
  if not window.is_visible() then
    vim.api.nvim_win_close(placeholder, true)
    return
  end
  local session = build.current()
  assert(session, "changeset: no open session")
  local ok, recorded = pcall(vim.json.decode, vim.g[POSITION_GLOBAL])
  apply(session.position:restore(ok and recorded or nil, draw.view(), decided))
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

-- The meta highlight is mixed from Comment's foreground, which a new colorscheme
-- replaces. Same idiom as lua/config/highlights.lua.
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("changeset.highlights", { clear = true }),
  desc = "changeset: rebuild the dim label colour against the new palette",
  callback = render.define_highlights,
})

-- Fires: every buffer or window switch and cursor move, sidebar open or not, so
-- "you are here" is current whenever the sidebar shows. Scheduled because a
-- preview swaps its buffer inside `nvim_win_call`, which fires these with the
-- borrowed window current; by the next tick focus is back where the user is.
vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "CursorMoved", "CursorMovedI" }, {
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

return M
