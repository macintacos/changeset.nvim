---Which lines of a text hold only a comment, a tool directive, or nothing, read with treesitter.

local M = {}

---@alias changeset.LineRuns { [1]: integer, [2]: integer }[] Ascending runs of 1-based lines, inclusive.

---A text's lines by kind; a line in no run is code.
---@class changeset.LineKinds
---@field comment changeset.LineRuns
---@field directive changeset.LineRuns
---@field blank changeset.LineRuns

---A file's comment data. `old` is nil when the file has no base side or git could not read it.
---@class changeset.Comments
---@field new changeset.LineKinds
---@field old changeset.LineKinds?

-- Cached with each file: bump cache.lua's FORMAT when what reads as a comment or a directive changes.
-- Matched on a comment line's trimmed text.
local DIRECTIVES = {
  "^#!",
  "^//go:",
  "^//%s*@ts%-",
  "^//%s*eslint%-",
  "^/%*%s*eslint%-",
  "^%-%-%-@diagnostic",
  "^%-%-%s*selene:",
  "^%-%-%s*stylua:",
  "^#%s*type:",
  "^#%s*noqa",
  "^#%s*pylint:",
  "^#%s*fmt:",
}

-- An anchored query misses a docstring after a shebang or a comment, so the caller walks each body's children.
local PYTHON_BODIES = [[
(module) @body
(class_definition body: (block) @body)
(function_definition body: (block) @body)
]]

---One alternation over the grammar's named node types whose names hold "comment"; nil when it has none.
---@param lang string
---@return vim.treesitter.Query?
local function comment_query(lang)
  local types = {}
  for name, named in pairs(vim.treesitter.language.inspect(lang).symbols) do
    if named and name:find("comment") then
      types[#types + 1] = "(" .. name .. ")"
    end
  end
  if #types == 0 then
    return nil
  end
  return vim.treesitter.query.parse(lang, "[" .. table.concat(types, " ") .. "] @comment")
end

---The docstring statement heading a Python module or body, past any leading comments.
---@param body TSNode
---@return TSNode?
local function docstring(body)
  for child in body:iter_children() do
    if child:named() and child:type() ~= "comment" then
      local only_child = child:named_child_count() == 1 and child:named_child(0)
      return child:type() == "expression_statement" and only_child and only_child:type() == "string" and child or nil
    end
  end
end

---@param source string
---@param lang string
---@return TSNode[]
local function comment_spans(source, lang)
  local root = vim.treesitter.get_string_parser(source, lang, { injections = { [lang] = "" } }):parse()[1]:root()
  local spans = {}
  local query = comment_query(lang)
  if query then
    for _, node in query:iter_captures(root, source) do
      spans[#spans + 1] = node
    end
  end
  if lang == "python" then
    for _, match in vim.treesitter.query.parse(lang, PYTHON_BODIES):iter_matches(root, source) do
      for _, nodes in pairs(match) do
        spans[#spans + 1] = docstring(nodes[1])
      end
    end
  end
  return spans
end

---Append `lnum` to `runs`, extending the last run when it ends just above.
---@param runs changeset.LineRuns
---@param lnum integer
local function push(runs, lnum)
  local last = runs[#runs]
  if last and last[2] == lnum - 1 then
    last[2] = lnum
  else
    runs[#runs + 1] = { lnum, lnum }
  end
end

---Whether `node` covers `line`, 0-based `row`, from its first to last non-blank byte.
---@param line string
---@param row integer
---@param node TSNode
---@return boolean
local function spans_line(line, row, node)
  local sr, sc, er, ec = node:range()
  local first = line:find("%S")
  return first ~= nil and (row > sr or sc < first) and (row < er or ec >= #line:gsub("%s+$", ""))
end

---0-based rows one of `spans` covers from first to last non-blank byte.
---@param lines string[]
---@param spans TSNode[]
---@return table<integer, true>
local function covered_rows(lines, spans)
  local covered = {}
  for _, node in ipairs(spans) do
    local sr, _, er = node:range()
    for row = sr, er do
      if spans_line(lines[row + 1], row, node) then
        covered[row] = true
      end
    end
  end
  return covered
end

---@param lines string[]
---@param covered table<integer, true>
---@return changeset.LineKinds
local function classify(lines, covered)
  local kinds = { comment = {}, directive = {}, blank = {} }
  for i, line in ipairs(lines) do
    local trimmed = vim.trim(line)
    if trimmed == "" then
      push(kinds.blank, i)
    elseif covered[i - 1] then
      local directive = vim.iter(DIRECTIVES):any(function(pattern)
        return trimmed:find(pattern) ~= nil
      end)
      push(directive and kinds.directive or kinds.comment, i)
    end
  end
  return kinds
end

---The kinds of `source`'s lines, or nil when no parser for its language is installed or the parser fails.
---@param source string
---@param path string Its name, or failing that `source`'s content, picks the language.
---@return changeset.LineKinds?
function M.read(source, path)
  local lines = vim.split(source, "\n", { plain = true })
  local ft = vim.filetype.match({ filename = path, contents = lines })
  local lang = ft and vim.treesitter.language.get_lang(ft)
  if not (lang and vim.treesitter.language.add(lang)) then
    return nil
  end
  -- A grammar this cannot read keeps today's placement rather than raising into the walk.
  local ok, kinds = pcall(function()
    return classify(lines, covered_rows(lines, comment_spans(source, lang)))
  end)
  return ok and kinds or nil
end

---Whether `lnum` falls in one of `runs`, which ascend and never overlap.
---@param runs changeset.LineRuns
---@param lnum integer
---@return boolean
local function within(runs, lnum)
  local lo, hi = 1, #runs
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local run = runs[mid]
    if lnum < run[1] then
      hi = mid - 1
    elseif lnum > run[2] then
      lo = mid + 1
    else
      return true
    end
  end
  return false
end

local KINDS = { "comment", "directive", "blank" }

---What line `lnum` of the text `kinds` was read from holds.
---@param kinds changeset.LineKinds
---@param lnum integer 1-based.
---@return "comment"|"directive"|"blank"|"code"
function M.kind(kinds, lnum)
  for _, name in ipairs(KINDS) do
    if within(kinds[name], lnum) then
      return name
    end
  end
  return "code"
end

return M
