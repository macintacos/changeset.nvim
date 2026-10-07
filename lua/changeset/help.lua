---The sidebar's own key reference.
---
---which-key renders a buffer's local mappings straight from the mappings
---themselves, so the `desc` each key already carries is the whole registration:
---nothing is added to the user's which-key spec, and `?` still answers when
---which-key is not installed at all. The buffer holds more than the sidebar's
---own keys, so the others are lifted off it while which-key shows.

local M = {}

---A buffer-local mapper that records what it sets, for `show` to document.
---
---The ledger lives here because `show` is the only thing that reads it: a panel that
---maps its own keys and then asks what it mapped is one bookkeeping job, not two.
---@param buf integer
---@return fun(lhs: string, fn: function, desc: string) map
---@return string[] own The `lhs` of everything mapped through it, in the order set.
function M.mapper(buf)
  local own = {}
  return function(lhs, fn, desc)
    own[#own + 1] = lhs
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = desc })
  end,
    own
end

---The mappings on the sidebar's buffer that the sidebar itself set, and the rest.
---
---A buffer collects mappings from whoever wants one — a blanket `FileType`
---autocmd is all it takes — and another plugin's keys are not this sidebar's
---interface. Compared as keycodes, since `<C-v>` and `<C-V>` are one key.
---@param keymaps { lhs: string }[] As returned by `nvim_buf_get_keymap`.
---@param own string[] The `lhs` of every mapping the sidebar set.
---@return table[] mine
---@return table[] others
function M._own(keymaps, own)
  local wanted = {}
  for _, lhs in ipairs(own) do
    wanted[vim.keycode(lhs)] = true
  end
  local mine, others = {}, {}
  for _, keymap in ipairs(keymaps) do
    table.insert(wanted[vim.keycode(keymap.lhs)] and mine or others, keymap)
  end
  return mine, others
end

---Calls `show` with `others` lifted off `buf`, then puts them back, whether or not it raised.
---
---which-key lists the current buffer's mappings once its popup is up, whatever
---buffer it was handed. Its popup returns only once closed, and a key picked in it
---is typed after, so the key reaches the buffer's mappings as they were.
---@param buf integer
---@param others table[] As returned by `nvim_buf_get_keymap`.
---@param show fun()
local function without(buf, others, show)
  local ok, err = pcall(function()
    for _, keymap in ipairs(others) do
      vim.keymap.del("n", keymap.lhs, { buffer = buf })
    end
    show()
  end)
  -- A buffer wiped while the popup waited has nothing to restore.
  if vim.api.nvim_buf_is_valid(buf) then
    -- mapset() maps on the current buffer.
    vim.api.nvim_buf_call(buf, function()
      vim.iter(others):each(vim.fn.mapset)
    end)
  end
  assert(ok, err)
end

---One `lhs  desc` line per described mapping, keys padded into a column.
---@param keymaps { lhs: string, desc: string? }[] As returned by `nvim_buf_get_keymap`.
---@return string[]
function M._lines(keymaps)
  local rows, width = {}, 0
  for _, keymap in ipairs(keymaps) do
    -- A mapping with no description is not documentation.
    if keymap.desc then
      width = math.max(width, vim.fn.strdisplaywidth(keymap.lhs))
      rows[#rows + 1] = keymap
    end
  end

  table.sort(rows, function(a, b)
    return a.lhs < b.lhs
  end)

  return vim.tbl_map(function(row)
    return row.lhs .. (" "):rep(width - vim.fn.strdisplaywidth(row.lhs) + 2) .. row.desc
  end, rows)
end

---Show the keys changeset answers to on `buf`.
---@param buf integer The current buffer, which which-key lists: the sidebar's, the kind menu's or a review comment window's.
---@param own string[] The `lhs` of every mapping changeset set on it.
function M.show(buf, own)
  local mine, others = M._own(vim.api.nvim_buf_get_keymap(buf, "n"), own)
  local ok, wk = pcall(require, "which-key")
  if ok then
    return without(buf, others, function()
      wk.show({ global = false })
    end)
  end
  local lines = M._lines(mine)
  local width = math.min(vim.o.columns - 4, math.max(1, unpack(vim.tbl_map(vim.fn.strdisplaywidth, lines))))
  local height = math.min(vim.o.lines - 4, math.max(#lines, 1))
  local float = vim.api.nvim_create_buf(false, true)
  vim.bo[float].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(float, 0, -1, false, lines)
  -- Sized to the editor, not the current window, which can be a float a few rows tall. Never focused: focus leaving
  -- the review comment window would close it.
  local win = vim.api.nvim_open_win(float, false, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2) - 1,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Changeset ",
  })
  -- Fires: the next move, keystroke typed or window left where `?` was pressed, which is done with the list.
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertCharPre", "BufLeave", "WinLeave" }, {
    buffer = vim.api.nvim_get_current_buf(),
    once = true,
    callback = function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end,
  })
end

return M
