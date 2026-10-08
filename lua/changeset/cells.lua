---Display width: how many cells text takes, and the longest head or tail of it that fits.

local M = {}

M.ELLIPSIS = "…"

---@param text string
---@return integer
function M.width(text)
  return vim.fn.strdisplaywidth(text)
end

---The cells `chunks`' texts take together.
---@param chunks { [1]: string }[]
---@return integer
function M.chunks(chunks)
  local total = 0
  for _, chunk in ipairs(chunks) do
    total = total + M.width(chunk[1])
  end
  return total
end

---The longest head of `text` at most `room` cells wide, `""` when not even its first character fits.
---@param text string
---@param room integer
---@return string
function M.head(text, room)
  local n = vim.fn.strchars(text)
  while n > 0 and M.width(vim.fn.strcharpart(text, 0, n)) > room do
    n = n - 1
  end
  return vim.fn.strcharpart(text, 0, n)
end

---The longest tail of `text` at most `room` cells wide.
---@param text string
---@param room integer
---@return string
function M.tail(text, room)
  local from = 0
  while M.width(vim.fn.strcharpart(text, from)) > room do
    from = from + 1
  end
  return vim.fn.strcharpart(text, from)
end

---`text` cut to at most `room` cells, ending in an ellipsis when cut.
---@param text string
---@param room integer
---@return string
function M.clip(text, room)
  if M.width(text) <= room then
    return text
  end
  return M.head(text, room - M.width(M.ELLIPSIS)) .. M.ELLIPSIS
end

return M
