local M = {}

-- Must stay equal to `symbols.SEP`: `symbols.fit` trims a chain by splitting it on
-- its own separator, and the chains it is handed are joined with this one.
---@type string
local SEP = " › "

---A row of the sidebar tree. Files sit at the top; symbols, or an orphan group holding orphan hunks, nest below.
---@class changeset.Row
---@field id string           Stable identity: `path` for a file, then `\0`-joined names. A `chain` row carries its head's.
---@field kind "file"|"symbol"|"orphans"|"orphan"
---@field depth integer       0 for file rows.
---@field name string         Display text; a compressed chain is joined by " › ".
---@field path string         Repo-relative file path.
---@field lnum integer?       1-based jump target; nil when the row is not navigable.
---@field symbol_kind string? LSP kind name ("Method"), for icon lookup.
---@field added integer?      Nil on an ancestor row or a deleted file row, which carry no stat.
---@field removed integer?
---@field ancestor boolean    Shown only because a descendant changed.
---@field chain boolean?      True on the row standing in for a folded run of single-child symbols.
---@field status string?      File rows only.
---@field resolved boolean?   File rows only: whether a server has answered for this file yet.
---@field children changeset.Row[]

---Text of a line of `path` in the working tree, used to caption orphan hunks.
---@alias changeset.LineText fun(path: string, lnum: integer): string?

---@class changeset.Node
---@field sym MiniPickers.Symbol
---@field children changeset.Node[]
---@field changed boolean
---@field added integer
---@field removed integer

---Rebuild the symbol tree from `symbols.flatten`'s document-ordered list and its `depth` sequence.
---@param symbols MiniPickers.Symbol[]
---@return changeset.Node[]
local function nest(symbols)
  local roots, stack = {}, {}
  for _, sym in ipairs(symbols) do
    while #stack > 0 and stack[#stack].sym.depth >= sym.depth do
      stack[#stack] = nil
    end
    local node = { sym = sym, children = {}, changed = false, added = 0, removed = 0 }
    local siblings = stack[#stack] and stack[#stack].children or roots
    siblings[#siblings + 1] = node
    stack[#stack + 1] = node
  end
  return roots
end

---The new-file lines a hunk covers; a deletion hunk sits on the line it follows.
---@param hunk changeset.Hunk
---@return integer first
---@return integer last
local function span(hunk)
  return hunk.lnum, hunk.lnum + math.max(hunk.count, 1) - 1
end

---The deepest symbols intersecting `first..last`: a symbol counts only when none of its children do,
---so a class is not changed by an edit inside one of its methods.
---@param nodes changeset.Node[]
---@param first integer
---@param last integer
---@param out changeset.Node[]
---@return changeset.Node[]
local function deepest_hits(nodes, first, last, out)
  for _, node in ipairs(nodes) do
    if node.sym.range_lnum <= last and node.sym.range_end_lnum >= first then
      local before = #out
      deepest_hits(node.children, first, last, out)
      if #out == before then
        out[#out + 1] = node
      end
    end
  end
  return out
end

---How many of a hunk's added lines fall inside `sym`'s body.
---@param hunk changeset.Hunk
---@param sym MiniPickers.Symbol
---@return integer
local function added_inside(hunk, sym)
  if hunk.count == 0 then
    return 0
  end
  return math.min(hunk.lnum + hunk.count - 1, sym.range_end_lnum) - math.max(hunk.lnum, sym.range_lnum) + 1
end

---Credit `hunk` to the symbols it lands in.
---@param roots changeset.Node[]
---@param hunk changeset.Hunk
---@return boolean landed false when the hunk touches no symbol
local function attribute(roots, hunk)
  local first, last = span(hunk)
  local hits = deepest_hits(roots, first, last, {})
  for i, node in ipairs(hits) do
    node.changed = true
    node.added = node.added + added_inside(hunk, node.sym)
    -- Removed lines have no new-file position to split on, so the first symbol takes them all.
    node.removed = node.removed + (i == 1 and hunk.removed or 0)
  end
  return #hits > 0
end

---Rows for the changed symbols under `parent` and the ancestors needed to place them.
---@param nodes changeset.Node[]
---@param parent changeset.Row
---@return changeset.Row[]
local function symbol_rows(nodes, parent)
  local rows, seen = {}, {}
  for _, node in ipairs(nodes) do
    -- Nesting alone cannot separate two siblings of one name, which is what a
    -- function's overloads are. `#`-prefixed segments are already synthetic ids.
    local id = parent.id .. "\0" .. node.sym.name
    seen[id] = (seen[id] or 0) + 1
    local row = {
      id = seen[id] == 1 and id or ("%s\0#%d"):format(id, seen[id]),
      kind = "symbol",
      depth = parent.depth + 1,
      name = node.sym.name,
      path = parent.path,
      lnum = node.sym.lnum,
      symbol_kind = node.sym.kind,
      ancestor = not node.changed,
    }
    row.children = symbol_rows(node.children, row)
    if node.changed then
      row.added, row.removed = node.added, node.removed
    end
    if node.changed or #row.children > 0 then
      rows[#rows + 1] = row
    end
  end
  return rows
end

---Where to jump for `hunk`: a deletion at the very top of a file follows line 0, which cannot be jumped to.
---@param hunk changeset.Hunk
---@return integer
local function jump_line(hunk)
  return math.max(hunk.lnum, 1)
end

---@param hunk changeset.Hunk
---@param text string?
---@return string
local function orphan_name(hunk, text)
  local first = jump_line(hunk)
  local last = first + math.max(hunk.count, 1) - 1
  local label = last > first and ("L%d–%d"):format(first, last) or "L" .. first
  return text and text ~= "" and label .. " " .. text or label
end

---@param hunk changeset.Hunk
---@param group changeset.Row
---@param line_text changeset.LineText?
---@return changeset.Row
local function orphan_row(hunk, group, line_text)
  local lnum = jump_line(hunk)
  -- A deletion hunk has no new-file line of its own: `lnum` is the line it follows.
  local text = hunk.count > 0 and line_text and line_text(group.path, lnum) or nil
  return {
    id = group.path .. "\0#orphan:" .. lnum,
    kind = "orphan",
    depth = group.depth + 1,
    name = orphan_name(hunk, text and vim.trim(text)),
    path = group.path,
    lnum = lnum,
    added = hunk.added,
    removed = hunk.removed,
    ancestor = false,
    children = {},
  }
end

---One row per hunk under a single "Other changes" group.
---@param hunks changeset.Hunk[]
---@param parent changeset.Row
---@param line_text changeset.LineText?
---@return changeset.Row
local function orphans_row(hunks, parent, line_text)
  local group = {
    id = parent.path .. "\0#orphans",
    kind = "orphans",
    depth = parent.depth + 1,
    name = "Other changes",
    path = parent.path,
    lnum = jump_line(hunks[1]),
    added = 0,
    removed = 0,
    ancestor = false,
    children = {},
  }
  for i, hunk in ipairs(hunks) do
    group.children[i] = orphan_row(hunk, group, line_text)
    group.added = group.added + hunk.added
    group.removed = group.removed + hunk.removed
  end
  return group
end

---The first changed line of a file, or its top when it has no hunks (a pure rename, a binary file).
---@param hunks changeset.Hunk[]
---@return integer
local function first_change(hunks)
  return hunks[1] and jump_line(hunks[1]) or 1
end

---@param file changeset.File
---@param resolved boolean Whether a server has answered for this file yet.
---@return changeset.Row
local function file_row(file, resolved)
  local deleted = file.status == "deleted"
  return {
    id = file.path,
    resolved = resolved,
    kind = "file",
    depth = 0,
    name = file.path,
    path = file.path,
    lnum = not deleted and first_change(file.hunks) or nil,
    added = not deleted and file.added or nil,
    removed = not deleted and file.removed or nil,
    ancestor = false,
    status = file.status,
    children = {},
  }
end

---The rows under a file: its changed symbols, then the hunks that landed in none.
---@param file changeset.File
---@param symbols MiniPickers.Symbol[]
---@param parent changeset.Row
---@param line_text changeset.LineText?
---@return changeset.Row[]
local function file_children(file, symbols, parent, line_text)
  local roots, orphans = nest(symbols), {}
  for _, hunk in ipairs(file.hunks) do
    if not attribute(roots, hunk) then
      orphans[#orphans + 1] = hunk
    end
  end
  local children = symbol_rows(roots, parent)
  if #orphans > 0 then
    children[#children + 1] = orphans_row(orphans, parent, line_text)
  end
  return children
end

---Map what a branch changed onto the symbols that own it: one row per file, changed symbols beneath
---(with the ancestors needed to place them), and an "Other changes" group for hunks outside every symbol.
---
---A file absent from `symbols_by_path` is still resolving and gets no children; a file mapped to `{}`
---has no symbols, so all its hunks are orphans. A deleted file never gets children.
---@param files changeset.File[] Hunks ascending by line, as `git diff` emits them.
---@param symbols_by_path table<string, MiniPickers.Symbol[]> Flat `symbols.flatten` output by file path.
---@param line_text changeset.LineText? Captions orphan hunks; without it they are named by line range alone.
---@return changeset.Row[]
function M.build(files, symbols_by_path, line_text)
  local rows = {}
  for i, file in ipairs(files) do
    local symbols = symbols_by_path[file.path]
    local row = file_row(file, symbols ~= nil)
    if symbols and file.status ~= "deleted" then
      row.children = file_children(file, symbols, row, line_text)
    end
    rows[i] = row
  end
  return rows
end

---Follow single-child links down from a symbol row; a row with two children, or none, ends the chain.
---@param row changeset.Row
---@return changeset.Row deepest
---@return string[] names Every name on the way down, `row`'s first.
local function chain(row)
  local deepest, names = row, { row.name }
  while deepest.kind == "symbol" and #deepest.children == 1 do
    deepest = deepest.children[1]
    names[#names + 1] = deepest.name
  end
  return deepest, names
end

local compress_rows

---Copy the run from `row` down to `deepest` one row per level, then compress what hangs below it.
---@param row changeset.Row
---@param deepest changeset.Row
---@param depth integer
---@param is_open (fun(id: string): boolean)?
---@return changeset.Row
local function unfold(row, deepest, depth, is_open)
  local children = row == deepest and compress_rows(row.children, depth + 1, is_open)
    or { unfold(row.children[1], deepest, depth + 1, is_open) }
  return vim.tbl_extend("force", row, { depth = depth, children = children })
end

---@param row changeset.Row File or symbol row.
---@param depth integer
---@param is_open (fun(id: string): boolean)?
---@return changeset.Row
local function compress_row(row, depth, is_open)
  local deepest, names = chain(row)
  if #names == 1 or (is_open and is_open(row.id)) then
    return unfold(row, deepest, depth, is_open)
  end
  return vim.tbl_extend("force", deepest, {
    id = row.id,
    name = table.concat(names, SEP),
    depth = depth,
    chain = true,
    children = compress_rows(deepest.children, depth + 1, is_open),
  })
end

---@param rows changeset.Row[]
---@param depth integer Depth of `rows` in the output, which is shallower than their own once chains fold.
---@param is_open (fun(id: string): boolean)?
---@return changeset.Row[]
function compress_rows(rows, depth, is_open)
  local out = {}
  for i, row in ipairs(rows) do
    out[i] = (row.kind == "file" or row.kind == "symbol") and compress_row(row, depth, is_open) or row
  end
  return out
end

---Fold each maximal run of single-child symbol rows into one `chain` row named by the run and
---standing for its deepest symbol: position, kind and stat are the deepest's, the id is the head's.
---@param rows changeset.Row[] File rows from `build`; left unmodified.
---@param is_open (fun(id: string): boolean)? A run whose head id is open stays at full nesting.
---@return changeset.Row[]
function M.compress(rows, is_open)
  return compress_rows(rows, 0, is_open)
end

return M
