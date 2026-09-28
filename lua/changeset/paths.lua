---Project-root lookup, and the clipboard copy behind the sidebar's `y`.
local M = {}

---Project root for `buf` — git root via `vim.fs.root`, falling back to cwd.
---@param buf integer Buffer handle (0 for current).
---@return string root Absolute, normalized path.
function M.root(buf)
  local git = vim.fs.root(buf, { ".git" })
  return vim.fs.normalize(git or assert(vim.uv.cwd()))
end

---Set the `+` register and notify. `content` may be a string or list of strings.
---@param content string|string[]|nil
---@param label string Short description used in the notification.
function M.copy(content, label)
  local text, count
  if type(content) == "table" then
    local filtered = {}
    for _, s in ipairs(content) do
      if s and s ~= "" then
        table.insert(filtered, s)
      end
    end
    text = table.concat(filtered, "\n")
    count = #filtered
  else
    text = content
    count = (content and content ~= "") and 1 or 0
  end

  if count == 0 then
    vim.notify("Nothing to copy", vim.log.levels.WARN)
    return
  end

  vim.fn.setreg("+", text)
  local suffix = count > 1 and (" (%d)"):format(count) or ""
  vim.notify(("Copied %s%s"):format(label, suffix))
end

return M
