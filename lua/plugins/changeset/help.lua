---The sidebar's own key reference.
---
---which-key renders a buffer's local mappings straight from the mappings
---themselves, so the `desc` each key already carries is the whole registration:
---nothing is added to the user's which-key spec, and `?` still answers when
---which-key is not installed at all. What it is handed is a buffer of the
---sidebar's own keys, because the sidebar's buffer holds more than those.

local M = {}

---The buffer the last `?` handed to which-key, kept so each one replaces it.
---@type integer?
local staged

---The mappings on the sidebar's buffer that the sidebar itself set.
---
---A buffer collects mappings from whoever wants one — a blanket `FileType`
---autocmd is all it takes — and another plugin's keys are not this sidebar's
---interface. Compared as keycodes, since `<C-v>` and `<C-V>` are one key.
---@param keymaps { lhs: string }[] As returned by `nvim_buf_get_keymap`.
---@param own string[] The `lhs` of every mapping the sidebar set.
---@return table[]
function M._own(keymaps, own)
  local wanted = {}
  for _, lhs in ipairs(own) do
    wanted[vim.keycode(lhs)] = true
  end
  return vim.tbl_filter(function(keymap)
    return wanted[vim.keycode(keymap.lhs)] == true
  end, keymaps)
end

---A throwaway buffer carrying `keymaps` and nothing else.
---
---which-key describes whatever a buffer maps and takes no say in which of them,
---so bounding what it shows means giving it a buffer that maps only these. The
---callbacks come across with the keys, which is what keeps the popup's own
---keypresses working; they act on the sidebar's state, not on a buffer.
---@param keymaps { lhs: string, desc: string?, callback: function?, rhs: string? }[]
---@return integer buf
function M._stage(keymaps)
  if staged and vim.api.nvim_buf_is_valid(staged) then
    pcall(vim.api.nvim_buf_delete, staged, { force = true })
  end
  staged = vim.api.nvim_create_buf(false, true)
  for _, keymap in ipairs(keymaps) do
    vim.keymap.set("n", keymap.lhs, keymap.callback or keymap.rhs or "<Nop>", {
      buffer = staged,
      desc = keymap.desc,
      nowait = true,
    })
  end
  return staged
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

---Show the keys the sidebar answers to.
---@param buf integer The sidebar's buffer.
---@param own string[] The `lhs` of every mapping the sidebar set.
function M.show(buf, own)
  local mine = M._own(vim.api.nvim_buf_get_keymap(buf, "n"), own)
  local ok, wk = pcall(require, "which-key")
  if ok then
    return wk.show({ buf = M._stage(mine), global = false })
  end
  vim.lsp.util.open_floating_preview(M._lines(mine), "", {
    border = "rounded",
    title = " Changeset ",
  })
end

return M
