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
---@param rows changeset.Row[]
---@param query string Empty returns the tree untouched.
---@return changeset.Row[]
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

---Narrow the tree to the symbol kinds the user wants to see.
---
---A symbol of a hidden kind is replaced by its own children rather than taking
---them down with it, so hiding `Class` still shows the methods that changed
---inside one. Same rule `symbols.flatten` applies to its own kind filter, for the
---same reason: the kind you dropped is not the thing you were looking for.
---@param rows changeset.Row[]
---@param hidden table<string, true> LSP kind names to drop.
---@return changeset.Row[]
function M.by_kind(rows, hidden)
  if vim.tbl_isempty(hidden) then
    return rows
  end

  local function keep(list)
    local out = {}
    for _, row in ipairs(list) do
      local children = keep(row.children or {})
      if row.kind == "symbol" and hidden[row.symbol_kind] then
        vim.list_extend(out, children)
      else
        out[#out + 1] = vim.tbl_extend("force", row, { children = children })
      end
    end
    return out
  end
  return keep(rows)
end

---How many symbol rows of each kind the tree holds.
---@param rows changeset.Row[] Unfiltered, so a hidden kind still reports its size.
---@return table<string, integer>
function M.kind_counts(rows)
  local counts = {}
  local function walk(list)
    for _, row in ipairs(list) do
      if row.kind == "symbol" and row.symbol_kind then
        counts[row.symbol_kind] = (counts[row.symbol_kind] or 0) + 1
      end
      walk(row.children or {})
    end
  end
  walk(rows)
  return counts
end

---The hidden kinds this tree actually has.
---
---A set carried in from another branch can name kinds nothing here uses, and
---reporting those as hidden would send a reader looking for symbols that were
---never there.
---@param counts table<string, integer> From `kind_counts`.
---@param hidden table<string, true>
---@return string[] Sorted.
function M.hiding(counts, hidden)
  local out = {}
  for kind in pairs(hidden) do
    if counts[kind] then
      out[#out + 1] = kind
    end
  end
  table.sort(out)
  return out
end

return M
