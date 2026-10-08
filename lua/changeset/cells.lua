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
  -- Walked a character at a time so the cost grows with `room`, not `text`. Each is measured from the column it starts
  -- at, for a tab, and a composing mark joins the character before it, adding no width.
  local kept, used, char, at = 0, 0, "", 0
  local i = 1
  while i <= #text do
    local j = i + vim.str_utf_end(text, i)
    local next = text:sub(i, j)
    if char ~= "" and vim.fn.strdisplaywidth(char .. next, at) == used - at then
      char = char .. next
    else
      local width = vim.fn.strdisplaywidth(next, used)
      if used + width > room then
        break
      end
      char, at, used = next, used, used + width
    end
    kept, i = j, j + 1
  end
  return text:sub(1, kept)
end

---Where the character ending at byte `j` of `text` starts, its composing marks taken with it, and where its marks
---start.
---@param text string
---@param j integer
---@return integer start
---@return integer marks
local function char_before(text, j)
  local i = j + vim.str_utf_start(text, j)
  local marks = j + 1
  while i > 1 do
    local left = (i - 1) + vim.str_utf_start(text, i - 1)
    local base = text:sub(left, i - 1)
    if vim.fn.strdisplaywidth(base .. text:sub(i, j)) ~= vim.fn.strdisplaywidth(base) then
      break
    end
    marks, i = i, left
  end
  return i, marks
end

---The longest tail of `text` at most `room` cells wide.
---@param text string
---@param room integer
---@return string
function M.tail(text, room)
  if text:find("\t", 1, true) then
    -- ponytail: a tab's width hangs on everything before it, so text with one is re-measured whole at each cut.
    local from = 0
    while M.width(vim.fn.strcharpart(text, from)) > room do
      from = from + 1
    end
    return vim.fn.strcharpart(text, from)
  end
  local from, used = #text + 1, 0
  while from > 1 do
    local start, marks = char_before(text, from - 1)
    local width = M.width(text:sub(start, from - 1))
    if used + width > room then
      -- Composing marks without their character stand as one cell.
      if marks < from and used + 1 <= room then
        from = marks
      end
      break
    end
    from, used = start, used + width
  end
  return text:sub(from)
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
