---Window bookkeeping for the sidebar: which window previews land in, and how
---that window is put back when the sidebar is dismissed without committing.

local buffers = require("plugins.prtree.buffers")

local M = {}

local SIDEBAR_WIDTH = 44

---@type table<string, string>
local SPLIT_CMD = { vsplit = "vsplit", split = "split", tab = "tabnew" }

---@class prtree.Snapshot
---@field win integer
---@field buf integer
---@field cursor integer[]

---@type { win: integer?, buf: integer?, pinned: integer?, snapshot: prtree.Snapshot? }
local sidebar = {}

---The window a preview should go to.
---
---The window pinned at open wins for the sidebar's whole lifetime, so previews
---never wander between windows (and so the restore only has one window to undo).
---@param pinned integer? Window captured when the sidebar opened.
---@param candidates integer[] Fallbacks, most recently used first.
---@param usable fun(win: integer): boolean
---@return integer? win nil when nothing can hold a preview and a split is needed.
function M._pick_target(pinned, candidates, usable)
  if pinned and usable(pinned) then
    return pinned
  end
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

---@return integer
local function target()
  local win = M._pick_target(sidebar.pinned, vim.api.nvim_tabpage_list_wins(0), usable)
  if win then
    sidebar.pinned = win
    return win
  end
  -- Nothing left to preview into: the sidebar is the only window, so give the
  -- file a split of its own rather than borrowing the sidebar.
  vim.api.nvim_set_current_win(sidebar.win)
  vim.cmd("leftabove vsplit")
  sidebar.pinned = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(sidebar.win)
  return sidebar.pinned
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

---Open the sidebar, pinning the window that had focus as the preview target.
---@param buf integer Scratch buffer holding the tree.
---@return integer win
function M.open(buf)
  sidebar.pinned = vim.api.nvim_get_current_win()
  sidebar.snapshot = {
    win = sidebar.pinned,
    buf = vim.api.nvim_win_get_buf(sidebar.pinned),
    cursor = vim.api.nvim_win_get_cursor(sidebar.pinned),
  }

  vim.cmd("botright vsplit")
  sidebar.win = vim.api.nvim_get_current_win()
  sidebar.buf = buf
  vim.api.nvim_win_set_buf(sidebar.win, buf)
  vim.api.nvim_win_set_width(sidebar.win, SIDEBAR_WIDTH)

  local wo = vim.wo[sidebar.win]
  wo.number, wo.relativenumber, wo.signcolumn = false, false, "no"
  wo.wrap, wo.cursorline, wo.foldcolumn = false, true, "0"
  wo.winfixwidth = true
  wo.list = false
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
  vim.api.nvim_win_set_buf(win, buf)
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
---@param how "pinned"|"vsplit"|"split"|"tab"
function M.commit(path, lnum, how)
  local buf = buffers.load(path)
  if not buf then
    return vim.notify("PR Review Tree: cannot open " .. path, vim.log.levels.WARN)
  end
  -- Listed from here on: the user chose this file, so it is theirs now.
  vim.bo[buf].buflisted = true

  vim.api.nvim_set_current_win(target())
  if how ~= "pinned" then
    vim.cmd(SPLIT_CMD[how])
  end
  -- `m'` before moving is what makes <C-o> come back here, and it is the one
  -- place the sidebar is allowed to touch the jumplist.
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_buf(0, buf)
  if lnum then
    vim.api.nvim_win_set_cursor(0, { M._clamp(lnum, vim.api.nvim_buf_line_count(buf)), 0 })
    require("helpers.windows").reveal_cursor()
  end
  sidebar.snapshot = nil
end

---Close the sidebar. Unless a commit already claimed the jump, the pinned window
---goes back to the buffer and cursor it held when the sidebar opened.
function M.close()
  local snapshot = sidebar.snapshot
  local win = sidebar.win
  sidebar.win, sidebar.buf, sidebar.snapshot = nil, nil, nil

  if win and vim.api.nvim_win_is_valid(win) and #vim.api.nvim_tabpage_list_wins(0) > 1 then
    vim.api.nvim_win_close(win, true)
  end

  if snapshot and vim.api.nvim_win_is_valid(snapshot.win) then
    if vim.api.nvim_buf_is_valid(snapshot.buf) then
      vim.api.nvim_win_set_buf(snapshot.win, snapshot.buf)
      local last = vim.api.nvim_buf_line_count(snapshot.buf)
      vim.api.nvim_win_set_cursor(snapshot.win, { M._clamp(snapshot.cursor[1], last), snapshot.cursor[2] })
    end
    vim.api.nvim_set_current_win(snapshot.win)
  end
  sidebar.pinned = nil
end

---Move focus into the sidebar.
function M.focus()
  if M.is_visible() then
    vim.api.nvim_set_current_win(sidebar.win)
  end
end

return M
