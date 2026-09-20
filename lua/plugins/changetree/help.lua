---The sidebar's own key reference.
---
---which-key renders a buffer's local mappings straight from the mappings
---themselves, so the `desc` each key already carries is the whole registration:
---nothing is added to the user's which-key spec, and `?` still answers when
---which-key is not installed at all.

local M = {}

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

---Show the keys this buffer answers to.
---@param buf integer
function M.show(buf)
  local ok, wk = pcall(require, "which-key")
  if ok then
    return wk.show({ global = false })
  end
  vim.lsp.util.open_floating_preview(M._lines(vim.api.nvim_buf_get_keymap(buf, "n")), "", {
    border = "rounded",
    title = " Change Tree ",
  })
end

return M
