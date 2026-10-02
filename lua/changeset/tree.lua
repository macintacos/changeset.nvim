---Builds the row tree.

local comments = require("changeset.comments")
local sections = require("changeset.sections")

local M = {}

-- Must stay equal to `symbols.SEP`: `symbols.fit` trims a chain by splitting it on
-- its own separator, and the chains it is handed are joined with this one.
---@type string
local SEP = " › "

---A row of the sidebar tree. Sections sit at the top with files under them; symbols, or an orphan group
---holding orphan hunks, nest below.
---@class changeset.Row
---@field id string           Stable identity: `#key` for a section, then `\0`-joined segments. A `chain` row carries its head's.
---@field kind "section"|"file"|"symbol"|"orphans"|"orphan"
---@field depth integer       0 for a section row, 1 for a file row.
---@field name string         Display text; a compressed chain is joined by " › ".
---@field path string         Repo-relative file path; empty on a section row.
---@field lnum integer?       1-based jump target; nil when the row is not navigable.
---@field symbol_kind string? LSP kind name ("Method"), for icon lookup.
---@field added integer?      Nil on an ancestor row or a deleted file row, which carry no stat.
---@field removed integer?
---@field ancestor boolean    Shown only because a descendant changed.
---@field chain boolean?      True on the row standing in for a folded run of single-child symbols.
---@field tip string?         On a `chain` row, the id of the deepest row it stands for.
---@field range { [1]: integer, [2]: integer }? Lines a symbol's body or an orphan hunk covers, inclusive.
---@field status string?      File rows only.
---@field resolved boolean?   File rows only: whether this file's symbols are answered, or never read.
---@field files integer?      Section rows only: how many files the section holds, before any filter.
---@field icon string?        Section rows only: the directory name its section header's icon is looked up by.
---@field children changeset.Row[]

---A line of a file, repo-relative.
---@class changeset.Spot
---@field path string
---@field lnum integer

---@class changeset.Picked : changeset.Spot
---@field id string The row picked; `path` and `lnum` stand in for it once a rebuild drops it.

---Text of a line of `path` in the working tree, used to caption orphan hunks.
---@alias changeset.LineText fun(path: string, lnum: integer): string?

---What `build` reads of a file's lines beyond its hunks.
---@class changeset.tree.Lines
---@field text changeset.LineText? Captions orphan hunks; without it they are named by line range alone.
---@field comments table<string, changeset.Comments>? By file path; a file without an entry never gets a Docs copy.

---Which kinds of changed line a unit holds.
---@class changeset.tree.Flags
---@field comment boolean?
---@field code boolean? A directive counts as code.

---@class changeset.Node : changeset.tree.Flags
---@field sym changeset.Symbol
---@field children changeset.Node[]
---@field changed boolean
---@field added integer
---@field removed integer
---@field test boolean In a subtree the file's test rule marked.

---Rebuild the symbol tree from `symbols.flatten`'s document-ordered list and its `depth` sequence.
---@param symbols changeset.Symbol[]
---@param is_test changeset.SymbolRule?
---@return changeset.Node[]
local function nest(symbols, is_test)
  local roots, stack = {}, {}
  for _, sym in ipairs(symbols) do
    while #stack > 0 and stack[#stack].sym.depth >= sym.depth do
      stack[#stack] = nil
    end
    local parent = stack[#stack]
    local test = (parent ~= nil and parent.test) or (is_test ~= nil and is_test(sym))
    local node = { sym = sym, children = {}, changed = false, added = 0, removed = 0, test = test }
    local siblings = parent and parent.children or roots
    siblings[#siblings + 1] = node
    stack[#stack + 1] = node
  end
  return roots
end

---The line kinds a symbol's range reaches up over.
---@type table<string, true>
local ABOVE = { comment = true, directive = true }

---`symbols` with each range reaching up over the comment and directive lines directly above it, stopping
---below the previous sibling and never above the parent's own first line, so a doc comment belongs to what it
---documents. A symbol with nothing to reach over is kept as it is.
---@param symbols changeset.Symbol[] `symbols.flatten` order.
---@param kinds changeset.LineKinds The new side's.
---@return changeset.Symbol[]
local function widen(symbols, kinds)
  local out, widened_at_depth, original_at_depth = {}, {}, {}
  for i, sym in ipairs(symbols) do
    local prev_sibling, parent = widened_at_depth[sym.depth], original_at_depth[sym.depth - 1]
    local floor = math.max(prev_sibling and prev_sibling.range_end_lnum + 1 or 1, parent and parent.range_lnum or 1)
    local first = sym.range_lnum
    while first > floor and ABOVE[comments.kind(kinds, first - 1)] do
      first = first - 1
    end
    out[i] = first == sym.range_lnum and sym or vim.tbl_extend("force", sym, { range_lnum = first })
    widened_at_depth[sym.depth], original_at_depth[sym.depth] = out[i], sym
  end
  return out
end

---Note line `lnum`'s kind on `flags`; a blank line is neither comment nor code.
---@param flags changeset.tree.Flags
---@param kinds changeset.LineKinds? nil when the side could not be read, so every line is code.
---@param lnum integer
local function mark(flags, kinds, lnum)
  local kind = kinds and comments.kind(kinds, lnum) or "code"
  if kind == "comment" then
    flags.comment = true
  elseif kind ~= "blank" then
    flags.code = true
  end
end

---Who owns a hunk's lines.
---@class changeset.tree.Owner
---@field at fun(lnum: integer): changeset.tree.Flags The unit owning a new line; called with ascending lines.
---@field removed changeset.tree.Flags The unit owning every removed line.

---Mark each of `hunk`'s lines on the unit that owns it.
---@param hunk changeset.Hunk
---@param comment_lines changeset.Comments
---@param owner changeset.tree.Owner
local function judge(hunk, comment_lines, owner)
  for lnum = hunk.lnum, hunk.lnum + hunk.count - 1 do
    mark(owner.at(lnum), comment_lines.new, lnum)
  end
  for lnum = hunk.old_lnum, hunk.old_lnum + hunk.removed - 1 do
    mark(owner.removed, comment_lines.old, lnum)
  end
end

---@param flags changeset.tree.Flags
---@return boolean
local function is_docs(flags)
  return flags.comment == true and not flags.code
end

---The new-file lines a hunk covers; a deletion hunk sits on the line it follows.
---@param hunk changeset.Hunk
---@return integer first
---@return integer last
local function span(hunk)
  return hunk.lnum, hunk.lnum + math.max(hunk.count, 1) - 1
end

---Whether `sym`'s range meets `first..last`.
---@param sym changeset.Symbol
---@param first integer
---@param last integer
---@return boolean
local function touches(sym, first, last)
  return sym.range_lnum <= last and sym.range_end_lnum >= first
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
    if touches(node.sym, first, last) then
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
---@param sym changeset.Symbol
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
---@param comment_lines changeset.Comments?
---@return changeset.Node[] hits Empty when the hunk touches no symbol.
local function attribute(roots, hunk, comment_lines)
  local first, last = span(hunk)
  local hits = deepest_hits(roots, first, last, {})
  if comment_lines and #hits > 0 then
    -- Lines outside every hit, like removed ones, go to the first: a code line beside a doc comment keeps it code.
    local cursor = 1
    judge(hunk, comment_lines, {
      -- Hits are disjoint and in document order, so a cursor follows the ascending lines.
      at = function(lnum)
        while cursor < #hits and hits[cursor].sym.range_end_lnum < lnum do
          cursor = cursor + 1
        end
        return touches(hits[cursor].sym, lnum, lnum) and hits[cursor] or hits[1]
      end,
      removed = hits[1],
    })
  end
  for i, node in ipairs(hits) do
    node.changed = true
    node.added = node.added + added_inside(hunk, node.sym)
    -- Removed lines have no new-file position to split on, so the first symbol takes them all.
    node.removed = node.removed + (i == 1 and hunk.removed or 0)
  end
  return hits
end

---How many of `hunk`'s added lines fall inside a test subtree.
---@param nodes changeset.Node[]
---@param hunk changeset.Hunk
---@return integer
local function added_in_tests(nodes, hunk)
  local first, last = span(hunk)
  local added = 0
  for _, node in ipairs(nodes) do
    if touches(node.sym, first, last) then
      added = added + (node.test and added_inside(hunk, node.sym) or added_in_tests(node.children, hunk))
    end
  end
  return added
end

---One of the copies a file can show as: its path section's, Tests' or Docs'.
---@alias changeset.tree.Copy "kept"|"tests"|"docs"

---`file`'s hunks credited to its symbols.
---@class changeset.tree.Credited
---@field roots changeset.Node[]
---@field orphans table<changeset.tree.Copy, changeset.Hunk[]> Hunks that touch no symbol: under `docs` those whose changed lines hold a comment and no code, under `kept` the rest.
---@field test_stat changeset.diff.Stat Added lines inside a test subtree, and a hunk's removed lines when `attribute` hands them to a test.

---Credit `file`'s hunks to the symbol tree `roots`.
---@param file changeset.File
---@param roots changeset.Node[] From `nest`.
---@param comment_lines changeset.Comments?
---@return changeset.tree.Credited
local function credit(file, roots, comment_lines)
  local out = { roots = roots, orphans = { kept = {}, docs = {} }, test_stat = { added = 0, removed = 0 } }
  for _, hunk in ipairs(file.hunks) do
    local hits = attribute(roots, hunk, comment_lines)
    if #hits == 0 then
      local flags = {}
      if comment_lines then
        judge(hunk, comment_lines, {
          at = function()
            return flags
          end,
          removed = flags,
        })
      end
      table.insert(out.orphans[is_docs(flags) and "docs" or "kept"], hunk)
    else
      out.test_stat.added = out.test_stat.added + added_in_tests(roots, hunk)
      out.test_stat.removed = out.test_stat.removed + (hits[1].test and hunk.removed or 0)
    end
  end
  return out
end

---The copy a changed node's own change puts it in.
---@param node changeset.Node
---@return changeset.tree.Copy
local function destination(node)
  return is_docs(node) and "docs" or node.test and "tests" or "kept"
end

---Split credited `nodes` between the path section's copy, the Tests copy and the Docs copy. A node goes where its
---own change puts it, and bare to every other copy holding a descendant, so that descendant stays placed under it.
---@param nodes changeset.Node[]
---@return table<changeset.tree.Copy, changeset.Node[]>
local function split(nodes)
  local out = { kept = {}, tests = {}, docs = {} }
  for _, node in ipairs(nodes) do
    local own = node.changed and destination(node)
    for copy, children in pairs(split(node.children)) do
      if own == copy or #children > 0 then
        local overrides = own == copy and { children = children }
          or { children = children, changed = false, added = 0, removed = 0 }
        table.insert(out[copy], vim.tbl_extend("force", node, overrides))
      end
    end
  end
  return out
end

---@param a changeset.diff.Stat
---@param b { added: integer, removed: integer }
---@return changeset.diff.Stat
local function plus(a, b)
  return { added = a.added + b.added, removed = a.removed + b.removed }
end

---@param a { added: integer, removed: integer }
---@param b changeset.diff.Stat
---@return changeset.diff.Stat
local function minus(a, b)
  return { added = a.added - b.added, removed = a.removed - b.removed }
end

---Lines the Docs nodes under `nodes` account for.
---@param nodes changeset.Node[]
---@return changeset.diff.Stat all
---@return changeset.diff.Stat in_tests Those inside a test subtree.
local function docs_stat(nodes)
  local all, in_tests = { added = 0, removed = 0 }, { added = 0, removed = 0 }
  for _, node in ipairs(nodes) do
    local below, below_tests = docs_stat(node.children)
    all, in_tests = plus(all, below), plus(in_tests, below_tests)
    if node.changed and is_docs(node) then
      all = plus(all, node)
      in_tests = node.test and plus(in_tests, node) or in_tests
    end
  end
  return all, in_tests
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
      range = { node.sym.range_lnum, node.sym.range_end_lnum },
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

---The lines an orphan hunk is named by and counts as covering.
---@param hunk changeset.Hunk
---@return integer first
---@return integer last
local function orphan_span(hunk)
  local first = jump_line(hunk)
  return first, first + math.max(hunk.count, 1) - 1
end

---@param hunk changeset.Hunk
---@param text string?
---@return string
local function orphan_name(hunk, text)
  local first, last = orphan_span(hunk)
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
    id = group.id .. "\0#orphan:" .. lnum,
    kind = "orphan",
    depth = group.depth + 1,
    name = orphan_name(hunk, text and vim.trim(text)),
    path = group.path,
    lnum = lnum,
    range = { orphan_span(hunk) },
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
    id = parent.id .. "\0#orphans",
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

---A file row's id.
---@param section_id string
---@param path string
---@return string
local function file_id(section_id, path)
  return section_id .. "\0" .. path
end

---@param file changeset.File
---@param resolved boolean Whether this file's symbols are answered, or never read.
---@param section changeset.Row
---@return changeset.Row
local function file_row(file, resolved, section)
  local deleted = file.status == "deleted"
  return {
    id = file_id(section.id, file.path),
    resolved = resolved,
    kind = "file",
    depth = section.depth + 1,
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

---A section row's id.
---@param key changeset.SectionKey
---@return string
function M.section_id(key)
  return "#" .. key
end

---Every section row's id, whether or not the section holds a file.
---@return string[]
function M.section_ids()
  return vim.tbl_map(function(section)
    return M.section_id(section.key)
  end, sections.ORDER)
end

---@param section changeset.Section
---@return changeset.Row
local function section_row(section)
  return {
    id = M.section_id(section.key),
    kind = "section",
    depth = 0,
    name = section.label,
    path = "",
    icon = section.icon,
    files = 0,
    added = 0,
    removed = 0,
    ancestor = false,
    children = {},
  }
end

---Put a file row under its section and add its lines to the section's totals.
---@param section changeset.Row
---@param row changeset.Row
---@param stat { added: integer?, removed: integer? } The lines `row` accounts for; a deleted file's row carries none of its own.
local function append(section, row, stat)
  section.children[#section.children + 1] = row
  section.files = section.files + 1
  section.added = section.added + (stat.added or 0)
  section.removed = section.removed + (stat.removed or 0)
end

---What one copy of a file lists.
---@class changeset.tree.Part
---@field nodes changeset.Node[]
---@field orphans changeset.Hunk[]

---Hang `part`'s symbols under `row`, then its orphans under "Other changes".
---@param row changeset.Row A file row.
---@param part changeset.tree.Part
---@param line_text changeset.LineText?
---@return changeset.Row row
local function fill(row, part, line_text)
  row.children = symbol_rows(part.nodes, row)
  if #part.orphans > 0 then
    row.children[#row.children + 1] = orphans_row(part.orphans, row, line_text)
  end
  return row
end

---Each shown copy's share of `file`'s stat; the shares sum to git's count. Docs takes its own lines; Tests takes
---its test lines less the Docs units inside them when the path's copy shows too, and whichever of those two
---shows takes the rest. A lone copy carries the whole stat.
---@param file changeset.File
---@param credited changeset.tree.Credited
---@param shown table<changeset.tree.Copy, true>
---@return table<changeset.tree.Copy, changeset.diff.Stat>
local function shares(file, credited, shown)
  local copies = vim.tbl_keys(shown)
  if #copies <= 1 then
    return { [copies[1] or "kept"] = file }
  end
  local docs, docs_in_tests = docs_stat(credited.roots)
  for _, hunk in ipairs(credited.orphans.docs) do
    docs = plus(docs, hunk)
  end
  local out, rest = { docs = shown.docs and docs or nil }, minus(file, docs)
  if shown.tests then
    out.tests = shown.kept and minus(credited.test_stat, docs_in_tests) or rest
    rest = minus(rest, out.tests)
  end
  out.kept = shown.kept and rest or nil
  return out
end

---How far the tree has read a file's symbols; a deleted or Generated file is `skipped`, never read.
---@alias changeset.ReadStatus "reading"|"done"|"skipped"

---How far the tree has read `file`'s symbols.
---@param file changeset.File
---@param symbols_by_path table<string, changeset.Symbol[]>
---@return changeset.ReadStatus
function M.read_status(file, symbols_by_path)
  if file.status == "deleted" or sections.classify(file.path, file.generated) == "generated" then
    return "skipped"
  end
  return symbols_by_path[file.path] and "done" or "reading"
end

---File `file` under its path's section, under Tests when its changes reach inline tests, and under Docs when
---some change only comments: each copy lists only its own symbols and "Other changes", and a copy with neither is
---left out. The copies' stats are `shares` of the file's.
---@param section_rows table<changeset.SectionKey, changeset.Row>
---@param file changeset.File
---@param symbols_by_path table<string, changeset.Symbol[]>
---@param lines changeset.tree.Lines
local function add_file(section_rows, file, symbols_by_path, lines)
  local key = sections.classify(file.path, file.generated)
  local section = section_rows[key]
  local status = M.read_status(file, symbols_by_path)
  if status ~= "done" then
    return append(section, file_row(file, status ~= "reading", section), file)
  end
  local symbols = symbols_by_path[file.path]
  local comment_lines = key ~= "docs" and lines.comments and lines.comments[file.path] or nil
  local credited = credit(
    file,
    nest(comment_lines and widen(symbols, comment_lines.new) or symbols, sections.test_rule(file.path)),
    comment_lines
  )
  local section_for = { kept = section, tests = section_rows.tests, docs = section_rows.docs }
  local rows, shown = {}, {}
  for copy, nodes in pairs(split(credited.roots)) do
    local part = { nodes = nodes, orphans = credited.orphans[copy] or {} }
    rows[copy] = fill(file_row(file, true, section_for[copy]), part, lines.text)
    shown[copy] = #rows[copy].children > 0 or nil
  end
  for copy, stat in pairs(shares(file, credited, shown)) do
    rows[copy].added, rows[copy].removed = stat.added, stat.removed
    append(section_for[copy], rows[copy], stat)
  end
end

---Map what a branch changed onto the symbols that own it: one section row per non-empty section, one row per
---file under it, changed symbols beneath (with the ancestors needed to place them), and an "Other changes"
---group for hunks outside every symbol. A Rust, Python or TypeScript file whose changes reach inline tests shows
---under Tests too, holding just those tests. A symbol or orphan hunk whose changed lines are comments and no code
---shows under a Docs copy instead, a doc comment counting with the symbol below it. A copy is left out when it
---would be empty.
---
---A file absent from `symbols_by_path` is still reading and gets no children; a file mapped to `{}`
---has no symbols, so all its hunks are orphans. A deleted or Generated file is never read and never gets
---children: a Generated file's hunks are not worth a row each. A file row is `resolved` once its symbols are
---answered, or when they are never read.
---@param files changeset.File[] Hunks ascending by line, as `git diff` emits them.
---@param symbols_by_path table<string, changeset.Symbol[]> Flat `symbols.flatten` output by file path.
---@param lines changeset.tree.Lines?
---@return changeset.Row[]
function M.build(files, symbols_by_path, lines)
  local section_rows = {}
  for _, section in ipairs(sections.ORDER) do
    section_rows[section.key] = section_row(section)
  end
  for _, file in ipairs(files) do
    add_file(section_rows, file, symbols_by_path, lines or {})
  end
  return vim
    .iter(sections.ORDER)
    :map(function(section)
      return section_rows[section.key]
    end)
    :filter(function(row)
      return row.files > 0
    end)
    :totable()
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

---The kinds `compress_row` takes.
---@type table<string, true>
local UNFOLDS = { section = true, file = true, symbol = true }

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

---@param row changeset.Row Section, file or symbol row.
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
    tip = deepest.id,
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
    out[i] = UNFOLDS[row.kind] and compress_row(row, depth, is_open) or row
  end
  return out
end

---Fold each maximal run of single-child symbol rows into one `chain` row named by the run and
---standing for its deepest symbol: position, kind and stat are the deepest's, the id is the head's.
---@param rows changeset.Row[] Section rows from `build`; left unmodified.
---@param is_open (fun(id: string): boolean)? A run whose head id is open stays at full nesting.
---@return changeset.Row[]
function M.compress(rows, is_open)
  return compress_rows(rows, 0, is_open)
end

---The first of `rows` whose range holds `lnum`; siblings' ranges do not overlap.
---@param rows changeset.Row[]
---@param lnum integer
---@return changeset.Row?
local function enclosing(rows, lnum)
  for _, row in ipairs(rows) do
    if row.range and row.range[1] <= lnum and lnum <= row.range[2] then
      return row
    end
  end
end

---The innermost symbol under `row` whose range holds `lnum`.
---@param row changeset.Row A symbol row.
---@param lnum integer A line inside its range.
---@return changeset.Row
local function deepest_symbol(row, lnum)
  local inner = enclosing(row.children, lnum)
  return inner and deepest_symbol(inner, lnum) or row
end

---The file rows under `build`'s sections, in display order.
---@param rows changeset.Row[] Section rows.
---@return changeset.Row[]
function M.files(rows)
  return vim
    .iter(rows)
    :map(function(section)
      return section.children
    end)
    :flatten()
    :totable()
end

---The deepest symbol row under `file` whose body holds `lnum`, else its "Other changes" row when one of its
---hunks does.
---@param file changeset.Row
---@param lnum integer
---@return changeset.Row?
local function within(file, lnum)
  local symbol = enclosing(file.children, lnum)
  if symbol then
    return deepest_symbol(symbol, lnum)
  end
  for _, child in ipairs(file.children) do
    if child.kind == "orphans" and enclosing(child.children, lnum) then
      return child
    end
  end
end

---Whether match `a` outranks `b` from another copy of the same file.
---@param a changeset.Row
---@param b changeset.Row
---@return boolean
local function beats(a, b)
  return a.depth > b.depth or a.depth == b.depth and b.ancestor and not a.ancestor
end

---The row a line of a file belongs to: the deepest symbol row whose body holds it, else the file's
---"Other changes" row when one of its hunks does, else the file row. A file shown in several sections answers
---from the copy with the deeper match; on an equal-depth tie a changed row beats a bare ancestor, and any
---remaining tie or miss goes to the path section's copy.
---@param rows changeset.Row[] Section rows from `build`, uncompressed.
---@param path string Repo-relative.
---@param lnum integer
---@return changeset.Row? nil when the changeset does not hold `path`.
function M.locate(rows, path, lnum)
  local home_id = file_id(M.section_id(sections.classify(path)), path)
  local copies = {}
  for _, file in ipairs(M.files(rows)) do
    if file.path == path then
      table.insert(copies, file.id == home_id and 1 or #copies + 1, file)
    end
  end
  local best
  for _, file in ipairs(copies) do
    local found = within(file, lnum)
    if found and (not best or beats(found, best)) then
      best = found
    end
  end
  return best or copies[1]
end

---The row with `id`, at any depth.
---@param rows changeset.Row[]
---@param id string
---@return changeset.Row?
function M.find(rows, id)
  for _, row in ipairs(rows) do
    local found = row.id == id and row or M.find(row.children, id)
    if found then
      return found
    end
  end
end

---The row a pick stands on now: itself while the tree still holds it, else the row its line resolves to.
---@param rows changeset.Row[]
---@param picked changeset.Picked
---@return changeset.Row?
function M.relocate(rows, picked)
  return M.find(rows, picked.id) or M.locate(rows, picked.path, picked.lnum)
end

return M
