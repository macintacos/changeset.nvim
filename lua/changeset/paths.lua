---Project-root lookup, and the clipboard copy behind the sidebar's `y`.
local M = {}

---Project root for `buf` — git root via `vim.fs.root`, falling back to cwd.
---@param buf integer Buffer handle (0 for current).
---@return string root Absolute, normalized path.
function M.root(buf)
  local git = vim.fs.root(buf, { ".git" })
  return vim.fs.normalize(git or assert(vim.uv.cwd()))
end

---Puts `text` on the clipboard, or in the unnamed register when Neovim has no clipboard provider.
---@param text string
---@return string where "", or where the text went instead of the clipboard, for the end of a message.
function M.put(text)
  if vim.fn.has("clipboard") == 1 then
    vim.fn.setreg("+", text)
    return ""
  end
  vim.fn.setreg('"', text)
  return ' in the " register, with no clipboard provider'
end

---Put `text` on the clipboard, as `put` does, and notify.
---@param text string
---@param label string Short description used in the notification.
function M.copy(text, label)
  vim.notify(("Copied %s%s"):format(label, M.put(text)))
end

return M
