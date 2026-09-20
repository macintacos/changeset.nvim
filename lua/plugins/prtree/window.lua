---Window bookkeeping for the sidebar: which window previews land in, and how
---that window is put back when the sidebar is dismissed without committing.

local buffers = require("plugins.prtree.buffers")
local render = require("plugins.prtree.render")

local M = {}

local SIDEBAR_WIDTH = 44

-- A session records the layout but not a scratch buffer's contents, so a
-- restored session brings the sidebar's window back empty. The buffer's name is
-- the one thing that survives, which makes it what tells that leftover window
-- apart from one the user opened.
local NAME = "prtree://"

---@type table<string, string>
local SPLIT_CMD = { vsplit = "vsplit", split = "split", tab = "tabnew" }

---@class prtree.Snapshot What a window held before the sidebar borrowed it.
---@field buf integer
---@field cursor integer[]
---@field winbar string

---@type { win: integer?, buf: integer?, borrowed: table<integer, prtree.Snapshot> }
local sidebar = { borrowed = {} }

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

---A window that can hold a file: still open, not the sidebar, not a special buffer.
---@param win integer
---@return boolean
local function usable(win)
  if not vim.api.nvim_win_is_valid(win) or win == sidebar.win then
    return false
  end
  if vim.api.nvim_win_get_config(win).relative ~= "" then
    return false
  end
  return vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ""
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
  -- file a split of its own rather than borrowing the sidebar.
  vim.api.nvim_set_current_win(sidebar.win)
  vim.cmd("leftabove vsplit")
  local fresh = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(sidebar.win)
  return fresh
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

---@return boolean
function M.is_visible()
  return sidebar.win ~= nil and vim.api.nvim_win_is_valid(sidebar.win)
end

---@return boolean
function M.is_focused()
  return M.is_visible() and vim.api.nvim_get_current_win() == sidebar.win
end

---@return integer? buf
function M.buf()
  return sidebar.buf
end

---@return integer? win
function M.win()
  return sidebar.win
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

---Open the sidebar.
---@param buf integer Scratch buffer holding the tree.
---@return integer win
function M.open(buf)
  local placeholder = M.placeholder()
  sidebar.borrowed = {}

  if placeholder then
    local stale = vim.api.nvim_win_get_buf(placeholder)
    sidebar.win = placeholder
    vim.api.nvim_win_set_buf(placeholder, buf)
    pcall(vim.api.nvim_buf_delete, stale, { force = true })
  else
    sidebar.win = vim.api.nvim_open_win(buf, false, { split = "right", win = -1, width = SIDEBAR_WIDTH })
  end
  sidebar.buf = buf
  vim.api.nvim_buf_set_name(buf, NAME .. buf)

  local wo = vim.wo[sidebar.win]
  wo.number, wo.relativenumber, wo.signcolumn = false, false, "no"
  wo.wrap, wo.cursorline, wo.foldcolumn = false, true, "0"
  wo.winfixwidth = true
  wo.list = false

  -- Opening a window is the editor's business to settle, and 'equalalways' is
  -- where the user said how. `winfixwidth` is already set, so the sidebar keeps
  -- its width and only the windows that were there share out what is left.
  if not placeholder and vim.o.equalalways then
    vim.cmd("wincmd =")
  end
  return sidebar.win
end

---Show `path` at `lnum` in the pinned window without leaving the sidebar.
---
---Deliberately not a jump: `nvim_win_set_cursor` records no jumplist entry, so
---holding `j` in the sidebar cannot fill `<C-o>` with one entry per keypress.
---@param path string
---@param lnum integer? A deletion hunk at the top of a file reports 0, so this is clamped.
function M.preview(path, lnum)
  local buf = buffers.load(path)
  if not buf then
    return
  end
  local win = target()
  remember(win)
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].winbar = render.preview_winbar(vim.fn.fnamemodify(path, ":."))
  if lnum then
    local last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
    vim.api.nvim_win_set_cursor(win, { M._clamp(lnum, last), 0 })
    vim.api.nvim_win_call(win, function()
      require("helpers.windows").reveal_cursor()
    end)
  end
end

---Commit the previewed location: focus it, keep the jump, and list the buffer.
---@param path string
---@param lnum integer?
---@param how "reuse"|"vsplit"|"split"|"tab"
function M.commit(path, lnum, how)
  local buf = buffers.load(path)
  if not buf then
    return vim.notify("PR Review Tree: cannot open " .. path, vim.log.levels.WARN)
  end
  -- Listed from here on: the user chose this file, so it is theirs now.
  vim.bo[buf].buflisted = true

  local win = target()
  local borrowed = sidebar.borrowed[win]
  vim.api.nvim_set_current_win(win)
  if how ~= "reuse" then
    vim.cmd(SPLIT_CMD[how])
  end
  -- A window showing a file you chose is not previewing it, and a new window
  -- copies its options from the one it was split off: either way the band stops
  -- here rather than following the file out.
  if borrowed then
    vim.wo[0].winbar = borrowed.winbar
  end
  -- `m'` before moving is what makes <C-o> come back here, and it is the one
  -- place the sidebar is allowed to touch the jumplist.
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_buf(0, buf)
  if lnum then
    vim.api.nvim_win_set_cursor(0, { M._clamp(lnum, vim.api.nvim_buf_line_count(buf)), 0 })
    require("helpers.windows").reveal_cursor()
  end
  -- Chosen, not borrowed: this window keeps what it is showing.
  sidebar.borrowed[vim.api.nvim_get_current_win()] = nil
end

---Close the sidebar. Every window it previewed into goes back to the buffer and
---cursor it held first; the one a commit claimed keeps what it was given.
function M.close()
  -- Resolved before the sidebar goes, while `winnr("#")` still names the window
  -- the cursor in it came from.
  local focus = M._pick_target(reachable(), usable)
  local borrowed, win = sidebar.borrowed, sidebar.win
  sidebar.win, sidebar.buf, sidebar.borrowed = nil, nil, {}

  if win and vim.api.nvim_win_is_valid(win) and #vim.api.nvim_tabpage_list_wins(0) > 1 then
    vim.api.nvim_win_close(win, true)
  end

  for borrower, snapshot in pairs(borrowed) do
    if vim.api.nvim_win_is_valid(borrower) then
      if vim.api.nvim_buf_is_valid(snapshot.buf) then
        vim.api.nvim_win_set_buf(borrower, snapshot.buf)
        local last = vim.api.nvim_buf_line_count(snapshot.buf)
        vim.api.nvim_win_set_cursor(borrower, { M._clamp(snapshot.cursor[1], last), snapshot.cursor[2] })
      end
      -- After the buffer, which brings its own remembered window options with
      -- it, and unconditionally: a window that has outlived what it was holding
      -- must still stop saying it is previewing.
      vim.wo[borrower].winbar = snapshot.winbar
    end
  end

  if focus and vim.api.nvim_win_is_valid(focus) then
    vim.api.nvim_set_current_win(focus)
  end
end

---Move focus into the sidebar.
function M.focus()
  if M.is_visible() then
    vim.api.nvim_set_current_win(sidebar.win)
  end
end

return M
