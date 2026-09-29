---Flattens an LSP document-symbol tree while keeping its shape.
---
---`vim.lsp.util.symbols_to_items` recurses into `children` and appends them to
---one flat list, discarding the nesting — so changeset requests
---`textDocument/documentSymbol` itself and walks the response through here.
---Every item also carries its tree position (`guides`, `crumb`), which changeset
---itself does not read.

---@class changeset.Symbol
---@field name string      Symbol name.
---@field text string      Same as `name`.
---@field kind string      Resolved `SymbolKind` name, e.g. "Function".
---@field path string      File the symbol lives in.
---@field lnum integer     1-based line of the symbol's name.
---@field col integer      1-based byte column of the symbol's name.
---@field end_lnum integer 1-based end line of the symbol's name.
---@field end_col integer  1-based end byte column of the symbol's name.
---@field range_lnum integer     1-based first line of the symbol's body.
---@field range_end_lnum integer 1-based last line of the symbol's body.
---@field depth integer    0 for a top-level symbol.
---@field guides string    Tree connectors for the row, e.g. "│ └─". Empty at depth 0.
---@field crumb string     Ancestor names joined by "›". Empty at depth 0.

---@class changeset.SymbolOpts
---@field bufnr? integer             Buffer the symbols describe (default: current).
---@field path? string               Path recorded on each item (default: `bufnr`'s name).
---@field encoding? string           Client offset encoding (default: "utf-16").
---@field kinds? table<string, true> Kinds to keep. Others are dropped and their
---                                  children promoted. Default: keep everything.

local M = {}

local SEP = " › "
local ELLIPSIS = "…"

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

---1-based byte column for a 0-based `character` offset on a 0-based `line`.
---@param bufnr integer
---@param line integer
---@param character integer
---@param encoding string
---@return integer
local function byte_col(bufnr, line, character, encoding)
  local text = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1]
  if text == nil then
    return character + 1
  end
  return vim.str_byteindex(text, encoding, character, false) + 1
end

---One level of the tree, in document order, after filtering.
---
---A node whose kind is filtered out is replaced by its own children rather than
---taking them down with it — otherwise a Lua file, whose tables come back as
---`Object`, would lose every function declared inside one.
---@param nodes table[]
---@param kinds table<string, true>?
---@return { node: table, kind: string }[]
local function level(nodes, kinds)
  local rows = {}
  for _, node in ipairs(nodes) do
    local kind = vim.lsp.protocol.SymbolKind[node.kind] or "Unknown"
    if kinds == nil or kinds[kind] then
      rows[#rows + 1] = { node = node, kind = kind }
    else
      vim.list_extend(rows, level(node.children or {}, kinds))
    end
  end
  table.sort(rows, precedes)
  return rows
end

---@param row { node: table, kind: string }
---@param ctx changeset.SymbolOpts
---@param depth integer
---@param guides string
---@param crumb string
---@return changeset.Symbol
local function to_item(row, ctx, depth, guides, crumb)
  local node, range = row.node, name_range(row.node)
  -- The name range locates a symbol; the body range is what a diff hunk lands
  -- inside. `SymbolInformation` has only the one range, and it is the body.
  local body = node.range or node.location.range
  return {
    name = node.name,
    text = node.name,
    kind = row.kind,
    path = node.location and vim.uri_to_fname(node.location.uri) or ctx.path,
    lnum = range.start.line + 1,
    col = byte_col(ctx.bufnr, range.start.line, range.start.character, ctx.encoding),
    end_lnum = range["end"].line + 1,
    end_col = byte_col(ctx.bufnr, range["end"].line, range["end"].character, ctx.encoding),
    range_lnum = body.start.line + 1,
    range_end_lnum = body["end"].line + 1,
    depth = depth,
    guides = guides,
    crumb = crumb ~= "" and crumb or (node.containerName or ""),
  }
end

---@param out changeset.Symbol[]
---@param nodes table[]
---@param ctx changeset.SymbolOpts
---@param depth integer
---@param bars string Ancestor bars this level's connectors hang off.
---@param crumb string
local function walk(out, nodes, ctx, depth, bars, crumb)
  local rows = level(nodes, ctx.kinds)
  for i, row in ipairs(rows) do
    local is_last = i == #rows
    -- Top-level rows carry no connector, so their children start theirs at
    -- column 0 and only depth 2 onward inherits bars.
    local guides = depth == 0 and "" or bars .. (is_last and "└─" or "├─")
    out[#out + 1] = to_item(row, ctx, depth, guides, crumb)
    walk(
      out,
      row.node.children or {},
      ctx,
      depth + 1,
      depth == 0 and "" or bars .. (is_last and "  " or "│ "),
      crumb == "" and row.node.name or crumb .. SEP .. row.node.name
    )
  end
end

---Flatten a `textDocument/documentSymbol` response into `changeset.Symbol`s.
---@param response table[] `DocumentSymbol[]` or `SymbolInformation[]`.
---@param opts changeset.SymbolOpts?
---@return changeset.Symbol[]
function M.flatten(response, opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local ctx = {
    bufnr = bufnr,
    path = opts.path or vim.api.nvim_buf_get_name(bufnr),
    encoding = opts.encoding or "utf-16",
    kinds = opts.kinds,
  }

  local out = {}
  walk(out, response, ctx, 0, "", "")
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
    local trimmed = ELLIPSIS .. sep .. table.concat(parts, sep)
    if vim.fn.strdisplaywidth(trimmed) <= width then
      return trimmed
    end
  end

  -- One segment, still too wide: keep its tail.
  local keep = width - 1
  if keep < 1 then
    return ELLIPSIS
  end
  return ELLIPSIS .. vim.fn.strcharpart(parts[1], vim.fn.strchars(parts[1]) - keep)
end

return M
