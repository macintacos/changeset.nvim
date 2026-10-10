---Reads, waits on and moves through the sidebar a spec opened.
local window = require("changeset.window")
local present = require("support.present")

local M = {}

---@return string[]
function M.lines()
  return vim.api.nvim_buf_get_lines(present(window.buf()), 0, -1, false)
end

---@return string
function M.text()
  return table.concat(M.lines(), "\n")
end

---Wait for the tree to hold `other.lua`, its symbols read or not.
function M.await_diff()
  local arrived = vim.wait(10000, function()
    return window.buf() ~= nil and M.text():find("other.lua", 1, true) ~= nil
  end, 25)
  assert.is_true(arrived, "the diff never arrived")
end

---Wait for the tree to hold `other.lua` with every file's symbols read.
function M.settle()
  local settled = vim.wait(10000, function()
    local text = window.buf() and M.text() or ""
    return text:find("other.lua", 1, true) ~= nil and not text:find("reading symbols", 1, true)
  end, 25)
  assert.is_true(settled, "the sidebar never settled")
end

---Let what the sidebar scheduled, such as its "you are here" tracking, run.
function M.flush()
  local flushed = false
  vim.schedule(function()
    flushed = true
  end)
  vim.wait(1000, function()
    return flushed
  end)
end

---The one sidebar line wearing `hl`, once the scheduled paint has run.
---@param hl string
---@return string?
function M.line_with(hl)
  M.flush()
  local ns = present(vim.api.nvim_get_namespaces()["changeset.rows"], "changeset.rows namespace missing")
  local lines = M.lines()
  local found = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(present(window.buf()), ns, 0, -1, { details = true })) do
    if present(mark[4]).hl_group == hl then
      table.insert(found, lines[mark[2] + 1])
    end
  end
  assert.is_true(#found <= 1, ("%d lines wear %s"):format(#found, hl))
  return found[1]
end

---Put the sidebar's cursor on the first line containing `text`, as `j`/`k` would.
---@param text string
function M.cursor_to(text)
  local win = present(window.win())
  vim.api.nvim_set_current_win(win)
  for i, line in ipairs(M.lines()) do
    if line:find(text, 1, true) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = window.buf() })
      return
    end
  end
  error("no sidebar line contains " .. text)
end

---Click the first sidebar line containing `text`. A UI-less Neovim takes no mouse input, so this presses the button
---where `getmousepos` says, answering as a terminal would for a click there.
---@param text string
function M.click(text)
  local win = present(window.win())
  for lnum, line in ipairs(M.lines()) do
    local col = line:find(text, 1, true)
    if col then
      local getmousepos = vim.fn.getmousepos
      vim.fn.getmousepos = function()
        return { winid = win, line = lnum, column = col }
      end
      local ok, err = pcall(vim.api.nvim_feedkeys, vim.keycode("<LeftMouse>"), "x", false)
      vim.fn.getmousepos = getmousepos
      ---@cast err string?
      assert.is_true(ok, err)
      M.flush()
      return
    end
  end
  error("no sidebar line contains " .. text)
end

---The text of the line the sidebar's cursor is on.
---@return string
function M.cursor_line()
  local win = present(window.win())
  return present(M.lines()[vim.api.nvim_win_get_cursor(win)[1]])
end

return M
