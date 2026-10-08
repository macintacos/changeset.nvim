---What the sidebar shows of the tree: its folds, opened chains, narrowing and
---hidden kinds, and the row on each line, with the moves that read and change them.

local render = require("changeset.render")
local Rows = require("changeset.rows")

---@class changeset.view.Folds
---@field collapsed table<string, true> Rows whose children are hidden.
---@field chains table<string, true> Compressed chains the user opened out.

---@class changeset.view.Layout
---@field icon fun(row: changeset.Row): string, string Glyph and highlight for a row.
---@field width integer
---@field cursor integer The cursor's line before this redraw.

---@class changeset.View
---@field private folds changeset.view.Folds Shared by every view of one repository root.
---@field private narrowed string The query rows must match; empty for none.
---@field private kinds_hidden table<string, true> Symbol kinds left out of the tree.
---@field private shown changeset.Row[] The row on each line, as `show` last laid them out.
---@field private laid changeset.Row[] The tree `show` last laid out, narrowed and compressed, before any fold.
local View = {}
View.__index = View

local M = {}

---Narrow the tree to rows matching `query`.
---
---A match keeps its ancestors, so a hit never floats free of the file it lives
---in, and keeps its own children, so matching a file still shows what changed
---inside it. A section never matches on its own label: it stays only while one of
---its rows does.
---@param rows changeset.Row[]
---@param query string Empty returns the tree untouched.
---@return changeset.Row[]
function M.filter(rows, query)
  if query == "" then
    return rows
  end
  local needle = query:lower()

  local function keep(row)
    if row.kind ~= "section" and row.name:lower():find(needle, 1, true) then
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

---Where the file holding line `lnum` stands among the files on screen; a file
---shown in several sections counts once.
---@param rows { depth: integer, path: string, kind: string? }[] One per line, as `render.lines` hands them back: 0 a section header, 1 a file or comment row.
---@param lnum integer
---@return integer? index nil on a section header's line or a comment row's, or when no file is at or above `lnum`.
---@return integer total
function M.position(rows, lnum)
  local index, total, index_of_path = nil, 0, {}
  for i, row in ipairs(rows) do
    if row.depth == 1 and row.kind ~= "comment" then
      if not index_of_path[row.path] then
        total = total + 1
        index_of_path[row.path] = total
      end
      if i <= lnum then
        index = index_of_path[row.path]
      end
    elseif row.depth == 0 and i <= lnum then
      index = nil
    end
  end
  return index, total
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

---Folds outlive the tree: a rebuild for a moved fork point, or a trip to another
---repository and back, keeps them. Kept per repository: row ids are built from
---repo-relative paths, so one table would share a fold between two checkouts that
---both have a `lua/config/options.lua`.
---@type table<string, changeset.view.Folds>
local folds_by_root = {}

---A view over `folds`, narrowed by nothing yet.
---@param folds changeset.view.Folds
---@param hidden table<string, true> Symbol kinds to leave out.
---@return changeset.View
function M.new(folds, hidden)
  return setmetatable({ folds = folds, narrowed = "", kinds_hidden = hidden, shown = {}, laid = {} }, View)
end

---A view sharing its folds with every other view of `root`; a root's first view starts with Generated folded.
---@param root string
---@param hidden table<string, true> Symbol kinds to leave out.
---@return changeset.View
function M.for_root(root, hidden)
  if not folds_by_root[root] then
    -- Only on creation, so an unfold is kept.
    folds_by_root[root] = { collapsed = { [Rows.section_id("generated")] = true }, chains = {} }
  end
  return M.new(folds_by_root[root], hidden)
end

---The line to put the cursor on after any redraw: the row it sat on, else, for a file row, the first file row
---with the same path (a file whose changes all turn out to be tests or comments moves to Tests or Docs; a filter
---can keep one copy and drop the others), else `fallback`.
---@param rows changeset.Row[] On screen, in display order.
---@param previous_row changeset.Row? The row the cursor sat on before the redraw.
---@param fallback integer Line to keep when nothing matches.
---@return integer lnum 1-based; within `rows` unless `rows` is empty.
local function reanchor(rows, previous_row, fallback)
  local same_file
  for lnum, row in ipairs(rows) do
    if previous_row and row.id == previous_row.id then
      return lnum
    end
    if
      not same_file
      and previous_row
      and previous_row.kind == "file"
      and previous_row.depth == 1
      and row.kind == "file"
      and row.path == previous_row.path
    then
      same_file = lnum
    end
  end
  return same_file or math.max(1, math.min(fallback, #rows))
end

---Narrow, compress and render `rows`, keeping the row on each line.
---@param rows changeset.Row[] The tree, uncompressed.
---@param layout changeset.view.Layout
---@return changeset.Line[] lines
---@return integer lnum Where the cursor goes: the row it sat on, wherever that is now.
function View:show(rows, layout)
  local previous_row = self.shown[layout.cursor]
  local compressed = Rows.compress(M.filter(M.by_kind(rows, self.kinds_hidden), self.narrowed), function(id)
    return self.folds.chains[id] == true
  end)
  self.laid = compressed
  -- `render.lines` walks the tree for its guides, so it is the one place that
  -- decides which rows are on screen; each line carries its row back, which is
  -- how a cursor line maps to a row without re-deriving that walk here.
  local lines = render.lines(compressed, {
    icon = layout.icon,
    collapsed = function(id)
      return self.folds.collapsed[id] == true
    end,
    width = layout.width,
    query = self.narrowed,
  })
  self.shown = vim.tbl_map(function(line)
    return line.row
  end, lines)
  return lines, reanchor(self.shown, previous_row, layout.cursor)
end

---The row on line `lnum`.
---@param lnum integer
---@return changeset.Row?
function View:row(lnum)
  return self.shown[lnum]
end

---The row on each line.
---@return changeset.Row[]
function View:visible()
  return self.shown
end

---The rows `show` last laid out, in display order, as they would read with every fold open.
---@return changeset.Row[]
function View:unfolded()
  local out = {}
  local function walk(rows)
    for _, row in ipairs(rows) do
      out[#out + 1] = row
      walk(row.children)
    end
  end
  walk(self.laid)
  return out
end

---Unfold every row the row with `id` sits under, so that it shows.
---@param id string
---@return boolean unfolded Whether any row was folded.
function View:reveal(id)
  local unfolded = false
  for folded in pairs(self.folds.collapsed) do
    if Rows.under(id, folded) then
      self.folds.collapsed[folded] = nil
      unfolded = true
    end
  end
  return unfolded
end

---Show more under the row on `lnum`: a shut chain's rows first, else its children.
---@param lnum integer
---@return boolean acted false when no row is on `lnum`.
function View:open(lnum)
  local row = self.shown[lnum]
  if not row then
    return false
  end
  -- Separate axes: compression hides a chain's *intermediate* rows, folding hides
  -- a row's children.
  if self.folds.collapsed[row.id] then
    self.folds.collapsed[row.id] = nil
  elseif row.chain and not self.folds.chains[row.id] then
    self.folds.chains[row.id] = true
  end
  return true
end

---Step out from `lnum`: fold its row while children show, else find its parent's line.
---@param lnum integer
---@return integer? parent The parent's line, when stepping out.
---@return boolean shut Whether the row was folded.
function View:step_out(lnum)
  local row = self.shown[lnum]
  if not row then
    return nil, false
  end
  -- Whether children are showing is read off the next line rather than the fold
  -- state, because a compressed chain shows them while it is itself still shut — so
  -- `h` closes one in the same two steps `l` opened it in.
  local below = self.shown[lnum + 1]
  if below and below.depth > row.depth then
    self.folds.collapsed[row.id] = true
    return nil, true
  end
  for i = lnum - 1, 1, -1 do
    if self.shown[i].depth < row.depth then
      return i, false
    end
  end
  return nil, false
end

---Fold every file row in `rows`.
---@param rows changeset.Row[] Section rows from `Rows.build`.
function View:fold_files(rows)
  for _, row in ipairs(Rows.files(rows)) do
    self.folds.collapsed[row.id] = true
  end
end

---Unfold every file and symbol row. Each section keeps its fold, even one empty for now, and opened chains stay open.
function View:unfold_files()
  local kept = {}
  for _, id in ipairs(Rows.section_ids()) do
    kept[id] = self.folds.collapsed[id]
  end
  self.folds.collapsed = kept
end

---The nearest row past `lnum` in `delta`'s direction that is not
---a section header, or the line itself when there is none that way.
---@param lnum integer
---@param delta integer 1 or -1.
---@return integer
function View:step(lnum, delta)
  local i = lnum + delta
  while self.shown[i] and self.shown[i].kind == "section" do
    i = i + delta
  end
  return self.shown[i] and i or lnum
end

---The nearest section header past `lnum` in `delta`'s direction, a folded
---one included, or the line itself when there is none that way.
---@param lnum integer
---@param delta integer 1 or -1.
---@return integer
function View:step_section(lnum, delta)
  local i = lnum + delta
  while self.shown[i] and self.shown[i].kind ~= "section" do
    i = i + delta
  end
  return self.shown[i] and i or lnum
end

---Keep only rows matching `query`; empty shows them all.
---@param query string
function View:narrow(query)
  self.narrowed = query
end

---The query the tree is narrowed by; empty for none.
---@return string
function View:query()
  return self.narrowed
end

---Leave the symbol kinds in `kinds` out of the tree.
---@param kinds table<string, true>
function View:hide(kinds)
  self.kinds_hidden = kinds
end

---The symbol kinds the tree leaves out.
---@return table<string, true>
function View:hidden()
  return self.kinds_hidden
end

return M
