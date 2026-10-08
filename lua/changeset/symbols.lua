---Flattens an LSP document-symbol tree while keeping its shape.
---
---`vim.lsp.util.symbols_to_items` recurses into `children` and appends them to
---one flat list, discarding the nesting — so changeset requests
---`textDocument/documentSymbol` itself and walks the response through here.

---@class changeset.Symbol
---@field name string      Symbol name.
---@field kind string      Resolved `SymbolKind` name, e.g. "Function".
---@field lnum integer     1-based line of the symbol's name.
---@field range_lnum integer     1-based first line of the symbol's body.
---@field range_end_lnum integer 1-based last line of the symbol's body.
---@field depth integer    0 for a top-level symbol.

local cells = require("changeset.cells")

local M = {}

local SEP = " › "

---The range naming a symbol: `DocumentSymbol.selectionRange`, or the whole
---`SymbolInformation.location.range` for servers that answer with the flat form.
---@param node table
---@return lsp.Range
local function name_range(node)
  return node.selectionRange or node.location.range
end

---@param a table
---@param b table
---@return boolean
local function precedes(a, b)
  local ra, rb = name_range(a.node), name_range(b.node)
  if ra.start.line ~= rb.start.line then
    return ra.start.line < rb.start.line
  end
  return ra.start.character < rb.start.character
end

local CALLABLE = { Function = true, Method = true, Constructor = true }

-- Kinds a server gives a function stored as a value: a TS arrow const, class-field arrow or getter.
local HOLDS_VALUE = { Variable = true, Constant = true, Property = true }
local LOCAL = { Variable = true, Constant = true }

---Whether `row` is a callable: a function, or a value declaring locals, which an object literal never does directly.
---@param row { node: table, kind: string }
---@return boolean
local function callable(row)
  if CALLABLE[row.kind] then
    return true
  end
  if not HOLDS_VALUE[row.kind] then
    return false
  end
  for _, child in ipairs(row.node.children or {}) do
    if LOCAL[vim.lsp.protocol.SymbolKind[child.kind]] then
      return true
    end
  end
  return false
end

-- What a callable keeps as children. Servers also list its locals, parameters and object keys, each of
-- which would take a line of the callable's change from it.
local IN_CALLABLE = {
  Function = true,
  Method = true,
  Constructor = true,
  Class = true,
  Interface = true,
  Struct = true,
  Enum = true,
  Module = true,
  Namespace = true,
}

---One level of the tree, in document order, after filtering.
---
---A node whose kind is filtered out is replaced by its own children rather than
---taking them down with it — otherwise a Lua file, whose tables come back as
---`Object`, would lose every function declared inside one.
---@param nodes table[]
---@param kinds table<string, true>?
---@param in_callable boolean? `nodes` are the children of a callable.
---@return { node: table, kind: string }[]
local function level(nodes, kinds, in_callable)
  local rows = {}
  for _, node in ipairs(nodes) do
    local kind = vim.lsp.protocol.SymbolKind[node.kind] or "Unknown"
    if kinds == nil or (kinds[kind] and (not in_callable or IN_CALLABLE[kind])) then
      rows[#rows + 1] = { node = node, kind = kind }
    else
      vim.list_extend(rows, level(node.children or {}, kinds, in_callable))
    end
  end
  table.sort(rows, precedes)
  return rows
end

---@param row { node: table, kind: string }
---@param depth integer
---@return changeset.Symbol
local function to_item(row, depth)
  local node = row.node
  -- The name range locates a symbol; the body range is what a diff hunk lands
  -- inside. `SymbolInformation` has only the one range, and it is the body.
  local body = node.range or node.location.range
  return {
    name = node.name,
    kind = row.kind,
    lnum = name_range(node).start.line + 1,
    range_lnum = body.start.line + 1,
    range_end_lnum = body["end"].line + 1,
    depth = depth,
  }
end

---@param out changeset.Symbol[]
---@param nodes table[]
---@param kinds table<string, true>?
---@param depth integer
---@param in_callable boolean?
local function walk(out, nodes, kinds, depth, in_callable)
  for _, row in ipairs(level(nodes, kinds, in_callable)) do
    out[#out + 1] = to_item(row, depth)
    walk(out, row.node.children or {}, kinds, depth + 1, callable(row))
  end
end

---@param p table LSP Position
---@param q table LSP Position
---@return boolean
local function before(p, q)
  return p.line < q.line or (p.line == q.line and p.character < q.character)
end

---@param outer table LSP Range
---@param inner table LSP Range
---@return boolean
local function contains(outer, inner)
  return not before(inner.start, outer.start) and not before(outer["end"], inner["end"])
end

---Nest a flat `SymbolInformation[]` by range containment, so each symbol sits under the
---nearest one whose range holds it, as a `DocumentSymbol` tree would.
---@param response table[]
---@return table[]
local function nest(response)
  local nodes = vim.tbl_map(function(info)
    return { name = info.name, kind = info.kind, location = info.location, children = {} }
  end, response)
  -- By start, the longer range first on a tie, so a parent always precedes what it holds.
  table.sort(nodes, function(a, b)
    local ra, rb = a.location.range, b.location.range
    if before(ra.start, rb.start) or before(rb.start, ra.start) then
      return before(ra.start, rb.start)
    end
    return before(rb["end"], ra["end"])
  end)
  local roots, stack = {}, {}
  for _, node in ipairs(nodes) do
    while #stack > 0 and not contains(stack[#stack].location.range, node.location.range) do
      stack[#stack] = nil
    end
    table.insert(#stack > 0 and stack[#stack].children or roots, node)
    stack[#stack + 1] = node
  end
  return roots
end

---Flatten a `textDocument/documentSymbol` response into `changeset.Symbol`s.
---@param response table[] `DocumentSymbol[]` or `SymbolInformation[]`.
---@param kinds table<string, true>? Kinds to keep. Others are dropped and their children promoted, as is
---anything under a function, method or constructor but a callable or a type. Default: keep everything.
---@return changeset.Symbol[]
function M.flatten(response, kinds)
  local out = {}
  local flat = response[1] and response[1].location and not response[1].range
  walk(out, flat and nest(response) or response, kinds, 0)
  return out
end

---Trim a separator-joined trail (a breadcrumb, a directory path) from the left so it fits `width` display cells.
---
---Nearest ancestors are the informative ones, so segments are dropped from the
---front and the trim is marked — the caller's window sets 'nowrap', which would
---otherwise cut off the end of the trail instead.
---@param trail string
---@param width integer
---@param sep? string Segment separator; defaults to " › "
---@return string
function M.fit(trail, width, sep)
  if vim.fn.strdisplaywidth(trail) <= width then
    return trail
  end

  sep = sep or SEP
  local parts = vim.split(trail, sep, { plain = true })
  while #parts > 1 do
    table.remove(parts, 1)
    local trimmed = cells.ELLIPSIS .. sep .. table.concat(parts, sep)
    if vim.fn.strdisplaywidth(trimmed) <= width then
      return trimmed
    end
  end

  -- One segment, still too wide: keep its tail.
  local keep = width - 1
  if keep < 1 then
    return cells.ELLIPSIS
  end
  return cells.ELLIPSIS .. cells.tail(parts[1], keep)
end

return M
