---Drives the dialog changeset has open, as the keys a user presses.
local present = require("support.present")

local M = {}

---The open dialog's window: the current window once it floats over a read-only buffer, which tells it from the
---review comment window. Waits a moment for one to open.
---@return integer?
function M.win()
  local win
  vim.wait(5000, function()
    local current = vim.api.nvim_get_current_win()
    if
      vim.api.nvim_win_get_config(current).relative ~= "" and not vim.bo[vim.api.nvim_win_get_buf(current)].modifiable
    then
      win = current
    end
    return win ~= nil
  end, 10)
  return win
end

---The open dialog's lines, trailing blanks dropped.
---@return string[]
function M.lines()
  local win = present(M.win(), "no dialog open")
  return vim.tbl_map(function(line)
    return (line:gsub("%s+$", ""))
  end, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false))
end

---The open dialog's title.
---@return string
function M.title()
  local title = present(vim.api.nvim_win_get_config(present(M.win(), "no dialog open")).title)
  return vim.trim(table.concat(vim.tbl_map(function(chunk)
    return chunk[1]
  end, title)))
end

---Presses `keys` in the open dialog.
---@param keys string In `vim.keycode` notation.
function M.press(keys)
  assert.not_nil(M.win(), "no dialog open")
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

---Clicks `text` on the dialog's lines. A UI-less Neovim takes no mouse input, so this releases the button where
---`getmousepos` says, answering as a terminal would for a click there.
---@param text string
function M.click(text)
  local win = present(M.win(), "no dialog open")
  for lnum, line in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)) do
    local col = line:find(text, 1, true)
    if col then
      local getmousepos = vim.fn.getmousepos
      vim.fn.getmousepos = function()
        return { winid = win, line = lnum, column = col }
      end
      local ok, err = pcall(M.press, "<LeftRelease>")
      vim.fn.getmousepos = getmousepos
      ---@cast err string?
      assert.is_true(ok, err)
      return
    end
  end
  error(("no %q on the dialog"):format(text))
end

return M
