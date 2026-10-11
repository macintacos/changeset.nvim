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
---@param root TSNode
---@return TSNode[]
local function comment_spans(source, lang, root)
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
        spans[#spans + 1] = docstring(assert(nodes[1], "changeset: a capture without a node"))
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
---@return table<integer, true?>
local function covered_rows(lines, spans)
  local covered = {}
  for _, node in ipairs(spans) do
    local sr, _, er = node:range()
    for row = sr, er do
      if spans_line(assert(lines[row + 1], "changeset: a node past the source's last line"), row, node) then
        covered[row] = true
      end
    end
  end
  return covered
end

---@param lines string[]
---@param covered table<integer, true?>
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

-- Far past any real parse, which 'redrawtime' already ends at 2 s by default.
local STALLED_PARSE_MS = 3000

---A parse of a text, which a later reader of the same text in the same language can reuse.
---@class changeset.Parsed
---@field lang string
---@field tree TSTree

---Parse `source` in slices across the main loop, calling `on_tree` with its tree: at once when the first slice
---finishes it, and nil when the parser raises.
---@param source string
---@param lang string
---@param on_tree fun(tree: TSTree?)
local function parse(source, lang, on_tree)
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, lang, { injections = { [lang] = "" } })
  if not ok then
    return on_tree(nil)
  end
  local answered = false
  local timer ---@type uv.uv_timer_t?
  local function answer(tree)
    if answered then
      return
    end
    answered = true
    if timer then
      timer:stop()
      timer:close()
    end
    on_tree(tree)
  end
  local function parse_whole()
    local done, whole = pcall(parser.parse, parser)
    answer(done and whole and whole[1] or nil)
  end
  local function finish(err, trees)
    -- A parse past 'redrawtime' gives up; finishing it whole keeps the answer a synchronous parse gives.
    if err == "TIMEOUT" then
      return parse_whole()
    end
    answer(trees and trees[1])
  end
  -- Only the parse is guarded: `on_tree` raising must reach the caller, not answer twice. So an answer the first
  -- slice gives waits for the pcall to return.
  local returned = false
  local early ---@type { err: string?, trees: table<integer, TSTree>? }?
  local started = pcall(parser.parse, parser, nil, function(err, trees)
    if returned then
      return finish(err, trees)
    end
    early = { err = err, trees = trees }
  end)
  returned = true
  if not started then
    return answer(nil)
  end
  if early then
    return finish(early.err, early.trees)
  end
  -- A slice that raises does so in Neovim's scheduled step, never calling back; this keeps the walk's lane moving.
  timer = vim.defer_fn(function()
    timer = nil
    parse_whole()
  end, STALLED_PARSE_MS)
end

---Read the kinds of `source`'s lines, calling back with nil when no parser for its language is installed or the
---parser fails. Parses in slices, so a large text calls back on a later tick; a small one usually before `read`
---returns.
---@param source string
---@param path string Its name, or failing that `source`'s content, picks the language.
---@param on_done fun(kinds: changeset.LineKinds?, parsed: changeset.Parsed?)
function M.read(source, path, on_done)
  local lines = vim.split(source, "\n", { plain = true })
  local ft = vim.filetype.match({ filename = path, contents = lines })
  local lang = ft and vim.treesitter.language.get_lang(ft)
  if not (lang and vim.treesitter.language.add(lang)) then
    return on_done(nil)
  end
  parse(source, lang, function(tree)
    if not tree then
      return on_done(nil)
    end
    -- A grammar this cannot read keeps today's placement rather than raising into the walk.
    local ok, kinds = pcall(function()
      return classify(lines, covered_rows(lines, comment_spans(source, lang, tree:root())))
    end)
    if not ok then
      return on_done(nil)
    end
    on_done(kinds, { lang = lang, tree = tree })
  end)
end

---Whether `lnum` falls in one of `runs`, which ascend and never overlap.
---@param runs changeset.LineRuns
---@param lnum integer
---@return boolean
local function within(runs, lnum)
  local lo, hi = 1, #runs
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local run = assert(runs[mid], "changeset: searched past the runs")
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
