---Shows a file's base in a window on its left, the two in diff mode: the side-by-side diff.

local M = {}

---Each file window's base window, and the file buffer it was opened for.
---@type table<integer, { win: integer, buf: integer }>
local partners = {}

---The file buffers this module put in diff mode, which a window showing one again takes 'diff' back from.
---@type table<integer, true>
local diffed = {}

---Show `base` beside `win`, which shows `buf`, the two diffed, reusing the base window `win` already has.
---@param win integer
---@param buf integer
---@param base integer The buffer holding the base's text.
function M.show(win, buf, base)
  local partner = partners[win]
  local base_win = partner and vim.api.nvim_win_is_valid(partner.win) and partner.win
  if base_win then
    vim.api.nvim_win_set_buf(base_win, base)
  else
    -- Held rather than `:diffsplit` in the current window, which may be the sidebar by now.
    base_win = vim.api.nvim_open_win(base, false, { split = "left", win = win })
  end
  partners[win] = { win = base_win, buf = buf }
  diffed[buf] = true
  vim.api.nvim_win_call(base_win, vim.cmd.diffthis)
  vim.api.nvim_win_call(win, vim.cmd.diffthis)
end

---Whether `win` shows its buffer beside the base window this module opened for it, as gitsigns' `get_view` checks.
---@param win integer
---@return boolean
function M.showing(win)
  local partner = partners[win]
  return partner ~= nil and vim.api.nvim_win_is_valid(partner.win) and partner.buf == vim.api.nvim_win_get_buf(win)
end

---Whether this module put `win` in diff mode, as a file window or a base window.
---@param win integer
---@return boolean
function M.owns(win)
  for file_win, partner in pairs(partners) do
    if file_win == win or partner.win == win then
      return true
    end
  end
  return false
end

---Close `win`'s base window and take `win` out of diff mode.
---@param win integer
function M.close(win)
  local partner = partners[win]
  partners[win] = nil
  if partner and vim.api.nvim_win_is_valid(partner.win) then
    vim.api.nvim_win_close(partner.win, true)
  end
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_call(win, vim.cmd.diffoff)
  end
end

---The file windows with a base window open, whether or not they still show the buffer it was opened for.
---@return integer[]
function M.paired()
  local wins = {}
  for win, partner in pairs(partners) do
    if vim.api.nvim_win_is_valid(partner.win) then
      wins[#wins + 1] = win
    end
  end
  return wins
end

---Take `win` out of diff mode when its buffer brought back a 'diff' this module set, as a window-local option comes back
---with the buffer it was set for, and no base window shows beside it.
---@param win integer
function M.scrub(win)
  if vim.wo[win].diff and diffed[vim.api.nvim_win_get_buf(win)] and not M.showing(win) then
    vim.api.nvim_win_call(win, vim.cmd.diffoff)
  end
end

---Close the base window of `closed`, a file window closing, unless that would leave no window.
---@param closed integer
function M.forget(closed)
  local partner = partners[closed]
  partners[closed] = nil
  if partner and vim.api.nvim_win_is_valid(partner.win) and #vim.api.nvim_list_wins() > 2 then
    vim.api.nvim_win_close(partner.win, true)
  end
end

return M
