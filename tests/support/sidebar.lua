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

---The file `win` shows and its cursor line.
---@param win integer
---@return string file, integer line
function M.shown(win)
  local buf = vim.api.nvim_win_get_buf(win)
  return vim.fs.basename(vim.api.nvim_buf_get_name(buf)), vim.api.nvim_win_get_cursor(win)[1]
end

---Wait for a sidebar opened before its fork point landed to stand.
function M.await_open()
  assert.is_true(
    vim.wait(10000, function()
      return window.is_visible()
    end, 10),
    "the sidebar never opened"
  )
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

---Redraw the sidebar at once on every rebuild. On a slow machine a redraw costing over a frame holds the next one back
---on a timer, which only `throttle_spec` is about.
---@return fun() restore
function M.draw_at_once()
  local changeset = require("changeset")
  local due = changeset._due
  changeset._due = function(now_ms)
    return now_ms
  end
  return function()
    changeset._due = due
  end
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

---Move the mouse pointer onto line `lnum` of `win`, as a terminal reports a move there, and let what it scheduled run.
---@param win integer
---@param lnum integer
function M.point_at(win, lnum)
  -- `getmousepos` finds no window on a screen that was never drawn, which a spec's isn't until it asks.
  vim.cmd.redraw()
  local pos = vim.fn.screenpos(win, lnum, 1)
  vim.api.nvim_input_mouse("move", "", "", 0, pos.row - 1, pos.col - 1)
  -- Takes the move out of the input queue, which only the main loop reads and a spec never reaches, so `on_key` sees
  -- it. `getchar` then skips it, answering 0. Feeding `<MouseMove>` instead would put the pointer back where the
  -- queue's first move left it.
  vim.fn.getchar(0)
  M.flush()
end

---Move the mouse pointer onto the first sidebar line containing `text`.
---@param text string
function M.point(text)
  for lnum, line in ipairs(M.lines()) do
    if line:find(text, 1, true) then
      M.point_at(present(window.win()), lnum)
      return
    end
  end
  error("no sidebar line contains " .. text)
end

---Move the mouse pointer onto the first sidebar line containing `text` as a typed move, which a map of `<MouseMove>`
---takes as it does a terminal's. Only the main loop maps a move `nvim_input_mouse` queued, so this feeds the key with
---`getmousepos` answering for the line, until what it scheduled has run. What was scheduled before runs first, as it
---would otherwise find the pointer there too.
---@param text string
function M.point_through_maps(text)
  M.flush()
  local win = present(window.win())
  for lnum, line in ipairs(M.lines()) do
    local col = line:find(text, 1, true)
    if col then
      local getmousepos = vim.fn.getmousepos
      vim.fn.getmousepos = function()
        return { winid = win, line = lnum, column = col }
      end
      local ok, err = pcall(function()
        vim.api.nvim_feedkeys(vim.keycode("<MouseMove>"), "xt", false)
        M.flush()
      end)
      vim.fn.getmousepos = getmousepos
      ---@cast err string?
      assert.is_true(ok, err)
      return
    end
  end
  error("no sidebar line contains " .. text)
end

---Press `key`, a mouse button, on the first sidebar line containing `text`. A UI-less Neovim takes no mouse input, so
---this presses it where `getmousepos` says, answering as a terminal would for a press there.
---@param text string
---@param key string
local function press(text, key)
  local win = present(window.win())
  for lnum, line in ipairs(M.lines()) do
    local col = line:find(text, 1, true)
    if col then
      local getmousepos = vim.fn.getmousepos
      vim.fn.getmousepos = function()
        return { winid = win, line = lnum, column = col }
      end
      local ok, err = pcall(vim.api.nvim_feedkeys, vim.keycode(key), "x", false)
      vim.fn.getmousepos = getmousepos
      ---@cast err string?
      assert.is_true(ok, err)
      M.flush()
      return
    end
  end
  error("no sidebar line contains " .. text)
end

---Click the first sidebar line containing `text`.
---@param text string
function M.click(text)
  press(text, "<LeftMouse>")
end

---Double-click the first sidebar line containing `text`: a click, then the press Neovim counts as the second.
---@param text string
function M.double_click(text)
  M.click(text)
  press(text, "<2-LeftMouse>")
end

---The text of the line the sidebar's cursor is on.
---@return string
function M.cursor_line()
  local win = present(window.win())
  return present(M.lines()[vim.api.nvim_win_get_cursor(win)[1]])
end

return M
