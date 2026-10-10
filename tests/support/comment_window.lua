---Finds and reads the review comment window: the float opened over a window.
local present = require("support.present")

local M = {}

---The review comment window, if one is open.
---@return integer?
function M.find()
  return vim.iter(vim.api.nvim_list_wins()):find(function(w)
    return vim.api.nvim_win_get_config(w).relative == "win"
  end)
end

---The review comment window, once one is open. Waits up to 2 s for it.
---@return integer?
function M.win()
  local win
  vim.wait(2000, function()
    win = M.find()
    return win ~= nil
  end, 10)
  return win
end

---The text of the review comment window `win`.
---@param win integer
---@return string
function M.text(win)
  return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
end

---The title of the review comment window `win`.
---@param win integer
---@return string
function M.title(win)
  local title = present(vim.api.nvim_win_get_config(win).title)
  return table.concat(vim.tbl_map(function(chunk)
    return chunk[1]
  end, title))
end

return M
