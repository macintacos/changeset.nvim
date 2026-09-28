---Inline tests a file's syntax marks where its symbol names cannot: a Rust item under `#[test]`,
---`#[<path>::test]` or `#[cfg(test)]`, and a TypeScript `if (import.meta.vitest) { … }` block.
---
---Takes text, not a buffer: the caller snapshots it as it asks the server, so its lines match the symbols'.

local M = {}

-- Each extension needs a `sections` name rule too: without one `test_rule` gives the file no rule, and its flags go
-- unread.
---@type table<string, string> Treesitter language by file extension.
local LANGS = { rs = "rust", ts = "typescript", mts = "typescript", cts = "typescript", tsx = "tsx" }

-- Cached with each symbol: bump cache.lua's FORMAT when what these mark changes.
-- `@test` is an attribute, standing for the item it sits on, or a block whose lines are all tests. Separate
-- patterns, not one alternation: predicates bind to a whole pattern, so shared captures would have to match all.
local RUST = [[
((attribute_item (attribute . (identifier) @name .)) @test (#eq? @name "test"))
((attribute_item (attribute . (scoped_identifier name: (identifier) @name))) @test (#eq? @name "test"))
((attribute_item
  (attribute . (identifier) @name arguments: (token_tree . (identifier) @arg .))) @test
  (#eq? @name "cfg") (#eq? @arg "test"))
]]
local VITEST = [[
(if_statement
  condition: (parenthesized_expression
    (member_expression object: (meta_property) property: (property_identifier) @name))
  consequence: (statement_block) @test
  (#eq? @name "vitest"))
]]
---@type table<string, string> By treesitter language.
local QUERIES = { rust = RUST, typescript = VITEST, tsx = VITEST }

---The item an attribute applies to: the next sibling past any further attributes and comments.
---@param node TSNode
---@return TSNode?
local function item_after(node)
  local item = node:next_named_sibling()
  while item and (item:type() == "attribute_item" or item:type():find("comment")) do
    item = item:next_named_sibling()
  end
  return item
end

---Lines of `source` holding tests, 1-based and inclusive.
---@param source string
---@param lang string
---@return { [1]: integer, [2]: integer }[]
local function test_regions(source, lang)
  local query = vim.treesitter.query.parse(lang, QUERIES[lang])
  local root = vim.treesitter.get_string_parser(source, lang, { injections = { [lang] = "" } }):parse()[1]:root()
  local test_capture = assert(vim.iter(pairs(query.captures)):find(function(_, name)
    return name == "test"
  end))
  local regions = {}
  -- Matches, not captures: `iter_captures` silently drops sibling matches past its `match_limit`.
  for _, match in query:iter_matches(root, source) do
    for _, node in ipairs(match[test_capture]) do
      local first, _, last = (node:type() == "attribute_item" and item_after(node) or node):range()
      regions[#regions + 1] = { first + 1, last + 1 }
    end
  end
  return regions
end

---Flag the `items` inside an inline test that `path`'s syntax marks, whatever their names. An item counts by its
---name's line, which lies inside the marked item whether or not a server's range for it takes in the attributes.
---@param items { lnum: integer, test: true? }[] Read from `source`; flagged in place. `lnum`: 1-based name line.
---@param path string Repo-relative; its extension picks the grammar.
---@param source string
function M.mark(items, path, source)
  local lang = LANGS[path:match("%.(%w+)$")]
  if not lang then
    return
  end
  -- No parser, or a grammar without these nodes: nothing is marked, and the name rules decide alone.
  local ok, regions = pcall(test_regions, source, lang)
  if not ok then
    return
  end
  for _, item in ipairs(items) do
    item.test = vim.iter(regions):any(function(region)
      return region[1] <= item.lnum and item.lnum <= region[2]
    end) or nil
  end
end

---@return string[]
function M.languages()
  local langs = vim.tbl_keys(vim.iter(vim.tbl_values(LANGS)):fold({}, function(set, lang)
    set[lang] = true
    return set
  end))
  table.sort(langs)
  return langs
end

return M
