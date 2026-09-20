---Narrowing the row tree to what the user asked to see.
---
---Which rows are *on screen* is the renderer's job — it walks the tree for the
---guides anyway, so it owns visibility and hands each line's row back. This is
---the other half: the transform that happens before that walk.

local M = {}

---Narrow the tree to rows matching `query`.
---
---A match keeps its ancestors, so a hit never floats free of the file it lives
---in, and keeps its own children, so matching a file still shows what changed
---inside it.
---@param rows changetree.Row[]
---@param query string Empty returns the tree untouched.
---@return changetree.Row[]
function M.filter(rows, query)
  if query == "" then
    return rows
  end
  local needle = query:lower()

  local function keep(row)
    if row.name:lower():find(needle, 1, true) then
      return row
    end
    local children = {}
    for _, child in ipairs(row.children or {}) do
      local kept = keep(child)
      if kept then
        children[#children + 1] = kept
      end
    end
    if #children == 0 then
      return nil
    end
    return vim.tbl_extend("force", row, { children = children })
  end

  local out = {}
  for _, row in ipairs(rows) do
    local kept = keep(row)
    if kept then
      out[#out + 1] = kept
    end
  end
  return out
end

return M
