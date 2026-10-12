---Shows a file's base in a window on its left, the two in diff mode: the side-by-side diff.

local M = {}

---Each file window's base window, and the file buffer it was opened for.
---@type table<integer, { win: integer, buf: integer }>
local partners = {}

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
  -- Marks a buffer that may bring this module's 'diff' back into another window, until its 'diff' is known off.
  vim.b[buf].changeset_diffed = true
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

---Close `win`'s base window, if it has one, and take `win` out of diff mode.
---@param win integer
function M.close(win)
  local partner = partners[win]
  if not partner then
    return
  end
  partners[win] = nil
  if vim.api.nvim_win_is_valid(partner.win) then
    vim.api.nvim_win_close(partner.win, true)
  end
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_call(win, vim.cmd.diffoff)
    if vim.api.nvim_win_get_buf(win) == partner.buf then
      vim.b[partner.buf].changeset_diffed = nil
    end
  end
end

---The file windows with a base window open.
---@return integer[]
function M.file_wins()
  return vim.tbl_keys(partners)
end

---Take `win` out of diff mode when its buffer brought back a 'diff' this module set, as a window-local option comes back
---with the buffer it was set for, and no base window shows beside it.
---@param win integer
function M.scrub(win)
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.wo[win].diff and vim.b[buf].changeset_diffed and not M.showing(win) then
    vim.api.nvim_win_call(win, vim.cmd.diffoff)
    vim.b[buf].changeset_diffed = nil
  end
end

---The windows of `tab` that aren't floating.
---@param tab integer
---@return integer[]
local function panes(tab)
  return vim.tbl_filter(function(w)
    return vim.api.nvim_win_get_config(w).relative == ""
  end, vim.api.nvim_tabpage_list_wins(tab))
end

---Close `win` unless it is the last window of the session that isn't floating.
---@param win integer
local function close_unless_last(win)
  if vim.api.nvim_win_is_valid(win) and (#vim.api.nvim_list_tabpages() > 1 or #panes(0) > 1) then
    vim.api.nvim_win_close(win, true)
  end
end

---Close the base window of `closed`, a file window closing.
---@param closed integer
function M.forget(closed)
  local partner = partners[closed]
  partners[closed] = nil
  if not (partner and vim.api.nvim_win_is_valid(partner.win)) then
    return
  end
  -- `closed` is still listed while WinClosed runs, and closing the last other window of its tabpage now aborts its close.
  if #panes(vim.api.nvim_win_get_tabpage(partner.win)) > 2 then
    vim.api.nvim_win_close(partner.win, true)
  else
    vim.schedule(function()
      close_unless_last(partner.win)
    end)
  end
end

---Close each base window a restored session brought back, which comes back empty since gitsigns reads no
---`gitsigns://` buffer back, and give each window `:diffthis` left folding by diff back its own 'foldmethod'.
function M.drop_restored()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.startswith(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)), "gitsigns://") then
      close_unless_last(win)
    end
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.wo[win].foldmethod == "diff" and not vim.wo[win].diff then
      vim.api.nvim_win_call(win, function()
        vim.cmd("setlocal foldmethod<")
      end)
    end
  end
end

return M
