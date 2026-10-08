---Window bookkeeping for the sidebar: which window previews land in, and how
---that window is put back when the sidebar is dismissed without committing.

local buffers = require("changeset.buffers")
local config = require("changeset.config")
local render = require("changeset.render")
local unified_diff = require("changeset.unified_diff")

local M = {}

local SIDEBAR_WIDTH = 44
local MIN_DRAWER_HEIGHT = 10

-- A session records the layout but not a scratch buffer's contents, so a
-- restored session brings the sidebar's window back empty. The buffer's name is
-- the one thing that survives, which makes it what tells that leftover window
-- apart from one the user opened.
local NAME = "changeset://"

---@type table<string, string>
local SPLIT_CMD = { vsplit = "vsplit", split = "split", tab = "tabnew" }

local stand_in_ns = vim.api.nvim_create_namespace("changeset.stand_in")

-- Normal and visual mode only: the filter prompt on the command line still needs
-- a cursor to type at.
local NO_CURSOR = "n-v:" .. render.NO_CURSOR_HL

---@class changeset.Snapshot What a window held before the sidebar borrowed it.
---@field buf integer
---@field cursor integer[]
---@field winbar string
---@field standing_buf integer? The buffer a preview put here while the cursor stood in the window.
---@field pick any What the caller previewed here, handed back when the window is claimed.

---Beside the files, or below them as a drawer.
---@alias changeset.Layout "sidebar"|"drawer"

---@type { win: integer?, buf: integer?, layout: changeset.Layout?, borrowed: table<integer, changeset.Snapshot> }
local sidebar = { borrowed = {} }

---@param columns integer The editor's width.
---@param min_file_width number The narrowest the files may get beside the sidebar.
---@return changeset.Layout
local function layout_for(columns, min_file_width)
  return columns - SIDEBAR_WIDTH < min_file_width and "drawer" or "sidebar"
end

---Where `layout` splits the tree off, as `nvim_open_win` and `nvim_win_set_config` take it.
---@param layout changeset.Layout
---@param lines integer The editor's height.
---@return vim.api.keyset.win_config
local function split_for(layout, lines)
  if layout == "drawer" then
    return { split = "below", win = -1, height = math.max(MIN_DRAWER_HEIGHT, math.floor(lines / 3)) }
  end
  return { split = "right", win = -1, width = SIDEBAR_WIDTH }
end

---Keep the size `layout` gave `win` when other windows open and close.
---@param win integer
---@param layout changeset.Layout
local function pin(win, layout)
  vim.wo[win].winfixwidth = layout == "sidebar"
  vim.wo[win].winfixheight = layout == "drawer"
end

---Windows a preview could go to, most recently used first.
---
---The window with focus is the one being read — except while the cursor is in
---the sidebar, when it is the window it came from. Offering both ahead of the
---rest is what makes a preview follow the user instead of staying wherever the
---sidebar happened to be opened from.
---@param current integer The focused window.
---@param previous integer The window focused before it, 0 when there is none.
---@param all integer[] Every window in the tabpage.
---@return integer[]
function M._candidates(current, previous, all)
  local out, seen = {}, {}
  for _, win in ipairs(vim.list_extend({ current, previous }, all)) do
    -- `winnr("#")` answers 0 once the window it named is closed, and 0 is an
    -- alias for the current window everywhere it would then be passed.
    if win > 0 and not seen[win] then
      seen[win] = true
      out[#out + 1] = win
    end
  end
  return out
end

---The first of `candidates` that can hold a file.
---@param candidates integer[] Windows, most recently used first.
---@param usable fun(win: integer): boolean
---@return integer? win nil when nothing can hold a preview and a split is needed.
function M._pick_target(candidates, usable)
  for _, win in ipairs(candidates) do
    if usable(win) then
      return win
    end
  end
  return nil
end

---A cursor line that exists in a buffer of `line_count` lines.
---
---Both ends matter. A deletion hunk at the top of a file is reported at line 0,
---and `nvim_buf_line_count` answers 0 for a buffer that is valid but unloaded —
---which a previewed-away buffer can be. Either one makes `nvim_win_set_cursor`
---throw "Invalid cursor line".
---@param lnum integer
---@param line_count integer
---@return integer
function M._clamp(lnum, line_count)
  return math.max(1, math.min(lnum, line_count))
end

---A window a preview can go to: still open, not the sidebar, not a float, and holding a file or a stand-in for one.
---@param win integer
---@return boolean
local function usable(win)
  if not vim.api.nvim_win_is_valid(win) or win == sidebar.win then
    return false
  end
  if vim.api.nvim_win_get_config(win).relative ~= "" then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  return vim.b[buf].changeset_stand_in or vim.bo[buf].buftype == ""
end

---Windows in this tabpage that can hold a file. A float is not one of them, and
---counting them is what decides whether the sidebar's window can be closed at all.
---@return integer[]
local function panes()
  return vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_config(win).relative == ""
  end, vim.api.nvim_tabpage_list_wins(0))
end

---@return integer[]
local function reachable()
  return M._candidates(
    vim.api.nvim_get_current_win(),
    vim.fn.win_getid(vim.fn.winnr("#")),
    vim.api.nvim_tabpage_list_wins(0)
  )
end

---@return integer
local function target()
  local win = M._pick_target(reachable(), usable)
  if win then
    return win
  end
  -- Nothing left to preview into: the sidebar is the only window, so give the
  -- file a split of its own rather than borrowing the sidebar. Split from inside
  -- `nvim_win_call`, which hands focus back without a `WinEnter` on the sidebar.
  local split = vim.api.nvim_win_call(sidebar.win, function()
    vim.cmd(sidebar.layout == "drawer" and "leftabove split" or "leftabove vsplit")
    return vim.api.nvim_get_current_win()
  end)
  -- Copied from the sidebar with the rest of its options.
  vim.wo[split].winfixbuf = false
  return split
end

---The window a commit would open into, without splitting for one; nil when there is none.
---@return integer?
function M.peek_target()
  return M._pick_target(reachable(), usable)
end

---Show `buf` in `win` without recording a jumplist entry.
---
---It is swapping the buffer, not moving the cursor, that records one — hence
---`keepjumps`, so holding `j` in the sidebar cannot fill `<C-o>` with one entry
---per keypress.
---@param win integer
---@param buf integer
local function show(win, buf)
  vim.api.nvim_win_call(win, function()
    vim.cmd({ cmd = "buffer", args = { buf }, mods = { keepjumps = true } })
  end)
end

---Put `win` back on what `remember` saw it holding.
---@param win integer
---@param snapshot changeset.Snapshot
local function put_back(win, snapshot)
  show(win, snapshot.buf)
  local last = vim.api.nvim_buf_line_count(snapshot.buf)
  vim.api.nvim_win_set_cursor(win, { M._clamp(snapshot.cursor[1], last), snapshot.cursor[2] })
end

---Note what `win` held, the first time the sidebar borrows it.
---@param win integer
local function remember(win)
  if sidebar.borrowed[win] then
    return
  end
  sidebar.borrowed[win] = {
    buf = vim.api.nvim_win_get_buf(win),
    cursor = vim.api.nvim_win_get_cursor(win),
    winbar = vim.wo[win].winbar,
  }
end

---Put `buf` in the window a preview goes to, remembering what that window held.
---@param buf integer
---@param band changeset.Band
---@param pick any Handed back by `claim`; nil clears whatever the last preview here left.
---@return integer win
local function borrow(buf, band, pick)
  local win = target()
  local standing = win == vim.api.nvim_get_current_win()
  remember(win)
  sidebar.borrowed[win].standing_buf = standing and buf or nil
  sidebar.borrowed[win].pick = pick
  show(win, buf)
  -- The band is for a window seen from the sidebar, never the one being read.
  if not standing then
    vim.wo[win].winbar = render.preview_winbar(band)
  end
  return win
end

---Take the band off the focused window, which is never a preview to the user.
---
---Stripped on arrival rather than only by `claim`: window options are remembered
---per buffer, so re-showing a buffer that was once previewed brings its band back
---with it, as does splitting a banded window — sidebar open or not.
function M.unband()
  local win = vim.api.nvim_get_current_win()
  if win == sidebar.win or not render.is_preview_winbar(vim.wo[win].winbar) then
    return
  end
  local snapshot = sidebar.borrowed[win]
  vim.wo[win].winbar = snapshot and snapshot.winbar or vim.go.winbar
end

---Whether the sidebar is on screen where the user is standing.
---
---A window in another tabpage is not: focusing it would haul the user out of the tab
---they are in, and every caller here means "can they see it from here". Nor is one
---that another buffer has taken over, which is the user's window now.
---@return boolean
function M.is_visible()
  return sidebar.win ~= nil
    and vim.api.nvim_win_is_valid(sidebar.win)
    and vim.tbl_contains(vim.api.nvim_tabpage_list_wins(0), sidebar.win)
    and M.buf() ~= nil
    and vim.api.nvim_win_get_buf(sidebar.win) == sidebar.buf
end

---Whether the cursor is in the sidebar.
---@return boolean
function M.is_focused()
  return M.is_visible() and vim.api.nvim_get_current_win() == sidebar.win
end

---The sidebar's buffer, or nothing once it has been wiped with its window.
---@return integer? buf
function M.buf()
  return sidebar.buf and vim.api.nvim_buf_is_valid(sidebar.buf) and sidebar.buf or nil
end

---The sidebar's window, or nothing when it is not there to be used.
---
---Guarded rather than raw: the window can go without the plugin being asked — `:q`,
---`:only`, `:tabclose` — and the callers all pass what they get here to the API.
---@return integer? win
function M.win()
  return M.is_visible() and sidebar.win or nil
end

---Hide the cursor while it is in the sidebar, where the cursor line marks the row
---and the cursor itself would sit on the row's icon.
function M.sync_cursor()
  if M.is_focused() then
    vim.opt.guicursor:append(NO_CURSOR)
  else
    vim.opt.guicursor:remove(NO_CURSOR)
  end
end

---The window a restored session left standing where the sidebar was.
---@return integer?
function M.placeholder()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
    if win ~= sidebar.win and name:find(NAME, 1, true) then
      return win
    end
  end
  return nil
end

---Move the tree beside the files when the editor is wide enough for both, and below
---them when it is not. The window is moved, not reopened, so it keeps its id.
function M.relayout()
  local layout = layout_for(vim.o.columns, config.get().layout.min_file_width)
  if not M.is_visible() or layout == sidebar.layout then
    return
  end
  sidebar.layout = layout
  pin(sidebar.win, layout)
  -- Neovim refuses to move the last window, which has no layout to change anyway.
  if #panes() > 1 then
    vim.api.nvim_win_set_config(sidebar.win, split_for(layout, vim.o.lines))
    if vim.o.equalalways then
      vim.cmd("wincmd =")
    end
  end
end

---Open the sidebar.
---@param buf integer Scratch buffer holding the tree.
---@return integer win
function M.open(buf)
  local placeholder = M.placeholder()
  sidebar.borrowed = {}

  if placeholder then
    local stale = vim.api.nvim_win_get_buf(placeholder)
    sidebar.win = placeholder
    -- A session saved with 'localoptions' brings it back.
    vim.wo[placeholder].winfixbuf = false
    vim.api.nvim_win_set_buf(placeholder, buf)
    pcall(vim.api.nvim_buf_delete, stale, { force = true })
    -- Laid out as the session was saved, which `relayout` below settles for this editor.
    sidebar.layout = nil
  else
    sidebar.layout = layout_for(vim.o.columns, config.get().layout.min_file_width)
    sidebar.win = vim.api.nvim_open_win(buf, false, split_for(sidebar.layout, vim.o.lines))
    pin(sidebar.win, sidebar.layout)
  end
  sidebar.buf = buf
  vim.api.nvim_buf_set_name(buf, NAME .. buf)

  local wo = vim.wo[sidebar.win]
  wo.number, wo.relativenumber, wo.signcolumn = false, false, "no"
  -- Rows are sized to the window's full width, and a global one draws even with
  -- every column above switched off.
  wo.statuscolumn = ""
  -- The selected row marks the cursor's line instead.
  wo.wrap, wo.cursorline, wo.foldcolumn = false, false, "0"
  -- For the sentence an empty tree shows, the one line `draw` lets wrap.
  wo.list, wo.linebreak = false, true
  -- Or a reflexive `<C-o>` there swaps the tree out of its window and wipes it.
  wo.winfixbuf = true
  M.relayout()

  -- Opening a window is the editor's business to settle, and 'equalalways' is
  -- where the user said how. The sidebar's size is already pinned, so it keeps
  -- it and only the windows that were there share out what is left.
  if not placeholder and vim.o.equalalways then
    vim.cmd("wincmd =")
  end
  -- A restored session can leave focus in the placeholder, which the sidebar
  -- takes over without a `WinEnter`.
  M.sync_cursor()
  return sidebar.win
end

-- Where a jump target should sit vertically in the window: 30% down from the
-- top, so the landing line has context above it and room to read below.
local REVEAL_RATIO = 0.3

---The top line that leaves at most `rows` screen lines above `lnum` in the current
---window, a closed fold counting as one.
---@param lnum integer
---@param rows integer
---@return integer
local function top_line(lnum, rows)
  local top = lnum
  while top > 1 do
    local above = vim.fn.foldclosed(top - 1)
    above = above == -1 and top - 1 or above
    if vim.api.nvim_win_text_height(0, { start_row = above - 1, end_row = lnum - 2 }).all > rows then
      break
    end
    top = above
  end
  return top
end

---Scroll the current window so the cursor line sits ~30% down from the top.
---Scrolls the view only — the cursor stays on the same buffer line, and
---'scrolloff' still wins over the 30%.
---
---Sets the top line instead of running `zt`/`<C-y>`: keys run here reach every
---`vim.on_key` listener as if typed in this window, and a preview runs this in a
---window the user is not in.
function M._reveal_cursor()
  local rows = math.floor(vim.api.nvim_win_get_height(0) * REVEAL_RATIO) - 1
  vim.fn.winrestview({ topline = top_line(vim.fn.line("."), rows) })
end

---Have gitsigns sign `buf`, now on screen in a preview.
---
---Previews swap buffers from a `CursorMoved` callback, where autocommands do not nest, so
---neither fires: `BufRead`, which gitsigns attaches on, nor `BufEnter`, which it waits for
---before signing a buffer it attached off screen, as it does every file the symbol walk
---loads. Only gitsigns' own `BufEnter` runs: any other would take the preview for a visit.
---@param buf integer
local function sign(buf)
  local ok, gitsigns = pcall(require, "gitsigns")
  if not ok then
    return
  end
  gitsigns.attach({ bufnr = buf })
  if vim.fn.exists("#gitsigns#BufEnter") == 1 then
    vim.api.nvim_exec_autocmds("BufEnter", { group = "gitsigns", buffer = buf, modeline = false })
  end
end

---Show `path` at `lnum` in the pinned window without leaving the sidebar.
---@param path string
---@param lnum integer? A deletion hunk at the top of a file reports 0, so this is clamped.
---@param band changeset.Band What the band over the window says about the file.
---@param pick any Handed back by `claim` if the cursor arrives in the preview.
function M.preview(path, lnum, band, pick)
  local buf = buffers.load(path)
  if not buf then
    return
  end
  local win = borrow(buf, band, pick)
  sign(buf)
  unified_diff.sync(win)
  if lnum then
    local last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
    vim.api.nvim_win_set_cursor(win, { M._clamp(lnum, last), 0 })
    vim.api.nvim_win_call(win, M._reveal_cursor)
  end
end

---Lines that put `text` in the middle of a `width` × `height` window.
---@param text string
---@param width integer
---@param height integer
---@return string[] lines
---@return integer row 0-based line holding `text`.
function M._centred(text, width, height)
  local row = math.floor(height / 2)
  local lines = {}
  for i = 1, row do
    lines[i] = ""
  end
  local pad = math.max(0, math.floor((width - vim.fn.strdisplaywidth(text)) / 2))
  lines[row + 1] = string.rep(" ", pad) .. text
  return lines, row
end

---A buffer to stand in for a file that can't be opened. A new one each time, so no filetype carries over from the
---last, which goes once no window shows it.
---@return integer buf
local function new_stand_in()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.b[buf].changeset_stand_in = true
  return buf
end

---Show `text` where a file preview would go, in place of a file.
---@param text string
---@param band changeset.Band What the band over the window says about the row.
function M.preview_notice(text, band)
  local buf = new_stand_in()
  local info = vim.fn.getwininfo(borrow(buf, band))[1]
  local lines, row = M._centred(text, info.width - info.textoff, info.height)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local line = lines[row + 1]
  vim.api.nvim_buf_set_extmark(buf, stand_in_ns, row, #line - #text, { end_col = #line, hl_group = render.META_HL })
end

---Show `text`, what `path` held before the branch deleted it, where a file preview would go: highlighted as its
---filetype, and every line tinted as the unified diff tints a deleted one.
---@param path string Names the filetype.
---@param text string
---@param band changeset.Band What the band over the window says about the row.
function M.preview_deleted(path, text, band)
  local buf = new_stand_in()
  local lines = vim.split((text:gsub("\n$", "")), "\n", { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_set_extmark(buf, stand_in_ns, 0, 0, { end_row = #lines - 1, line_hl_group = render.DIFF_DELETE_HL })
  -- Named before it is shown, as `buffers.load` names a file's, so its `FileType` handlers set nothing on the window.
  local filetype = vim.filetype.match({ buf = buf, filename = path })
  if filetype then
    vim.bo[buf].filetype = filetype
  end
  borrow(buf, band)
end

---Make `buf` the chosen contents of `win`: focus it, leave `<C-o>` pointing where
---the window stood before the sidebar, and list the buffer.
---@param win integer
---@param buf integer
---@param lnum integer?
---@param how "reuse"|"vsplit"|"split"|"tab"
local function promote(win, buf, lnum, how)
  -- Listed from here on: the user chose this file, so it is theirs now.
  vim.bo[buf].buflisted = true

  local snapshot = sidebar.borrowed[win]
  -- Chosen, not borrowed — and dropped before the focus below, whose `WinEnter`
  -- would otherwise have `claim` commit it a second time.
  sidebar.borrowed[win] = nil
  vim.api.nvim_set_current_win(win)
  -- On the snapshot first, so the entry below is the user's own position rather
  -- than the last preview — and before any split, since `:tabnew` records the
  -- position it leaves.
  if snapshot and vim.api.nvim_buf_is_valid(snapshot.buf) then
    put_back(0, snapshot)
  end
  vim.cmd("normal! m'")
  if how ~= "reuse" then
    vim.cmd(SPLIT_CMD[how])
  end
  show(0, buf)
  -- A window showing a file you chose is not previewing it, and a new window
  -- copies its options from the one it was split off: either way the band stops
  -- here rather than following the file out. After the swap, or it leaves with
  -- the buffer it was set on: window options are remembered per buffer.
  if snapshot then
    vim.wo[0].winbar = snapshot.winbar
  end
  if lnum then
    vim.api.nvim_win_set_cursor(0, { M._clamp(lnum, vim.api.nvim_buf_line_count(buf)), 0 })
    M._reveal_cursor()
  end
end

---Commit the previewed location in the window the preview went to.
---@param path string
---@param lnum integer?
---@param how "reuse"|"vsplit"|"split"|"tab"
---@return boolean committed false when the file could not be opened.
function M.commit(path, lnum, how)
  local buf = buffers.load(path)
  if not buf then
    vim.notify("Changeset: cannot open " .. path, vim.log.levels.WARN)
    return false
  end
  promote(target(), buf, lnum, how)
  return true
end

---Commit the focused window if the sidebar previewed into it from elsewhere:
---arriving at a preview by any route counts as choosing it, but one made where
---the cursor already stood was never arrived at.
---@return any pick What `preview` was given for the claimed window; nil when nothing was claimed.
function M.claim()
  local win = vim.api.nvim_get_current_win()
  local snapshot = M.is_visible() and sidebar.borrowed[win]
  local buf = vim.api.nvim_win_get_buf(win)
  -- A stand-in is for a file that cannot be opened, so there is nothing to choose.
  if not snapshot or snapshot.standing_buf == buf or vim.b[buf].changeset_stand_in then
    return
  end
  -- The user may have scrolled the preview before reaching it; the swaps inside
  -- the promote would lose that view.
  local view = vim.fn.winsaveview()
  promote(win, buf, nil, "reuse")
  vim.fn.winrestview(view)
  return snapshot.pick
end

---Close the sidebar. Every window it previewed into goes back to the buffer and
---cursor it held first; the one a commit claimed keeps what it was given.
function M.close()
  -- Resolved before the sidebar goes, while `winnr("#")` still names the window
  -- the cursor in it came from.
  local focus = M._pick_target(reachable(), usable)
  local borrowed, win = sidebar.borrowed, sidebar.win
  sidebar.win, sidebar.buf, sidebar.borrowed = nil, nil, {}

  if win and vim.api.nvim_win_is_valid(win) then
    if #panes() > 1 then
      vim.api.nvim_win_close(win, true)
    else
      -- The last window cannot be closed, and leaving the tree in it would leave a
      -- panel on screen whose keys no longer answer.
      vim.wo[win].winfixbuf = false
      vim.api.nvim_win_call(win, function()
        vim.cmd("enew")
      end)
      -- A new buffer takes the window's options, header and footer included.
      vim.wo[win].winbar, vim.wo[win].statusline = "", ""
    end
  end

  for borrowed_win, snapshot in pairs(borrowed) do
    if vim.api.nvim_win_is_valid(borrowed_win) then
      if vim.api.nvim_buf_is_valid(snapshot.buf) then
        put_back(borrowed_win, snapshot)
      end
      -- After the buffer, which brings its own remembered window options with
      -- it, and unconditionally: a window that has outlived what it was holding
      -- must still stop saying it is previewing.
      vim.wo[borrowed_win].winbar = snapshot.winbar
    end
  end

  if focus and vim.api.nvim_win_is_valid(focus) then
    vim.api.nvim_set_current_win(focus)
  end
  M.sync_cursor()
end

---Move focus into the sidebar.
function M.focus()
  if M.is_visible() then
    vim.api.nvim_set_current_win(sidebar.win)
  end
end

return M
