---What can be asked of one review comment's lines: its first line, its range, its order, its labels and where edits
---move them.

local M = {}

---@class changeset.ReviewComment
---@field path string Repo-relative.
---@field line integer? The last line, 1-based; nil for a comment on the whole file.
---@field start_line integer? The first line, only for a range.
---@field body string
---@field draft true? Kept but not saved, so submit and yank leave it out.

---@class changeset.ReviewCommentMove
---@field from changeset.ReviewComment As listed.
---@field to changeset.ReviewComment `from` on the lines it moves to.

---The first line of `comment`; nil for a whole file's.
---@param comment changeset.ReviewComment
---@return integer?
function M.first(comment)
  return comment.start_line or comment.line
end

---Whether `a` sorts ahead of `b`: by path, then first line, then last line, a whole file's comment first.
---@param a changeset.ReviewComment
---@param b changeset.ReviewComment
---@return boolean
function M.before(a, b)
  if a.path ~= b.path then
    return a.path < b.path
  end
  local a_first, b_first = M.first(a) or 0, M.first(b) or 0
  if a_first ~= b_first then
    return a_first < b_first
  end
  return (a.line or 0) < (b.line or 0)
end

---Whether `a` and `b` sit on the same path and lines.
---@param a changeset.ReviewComment
---@param b changeset.ReviewComment
---@return boolean
function M.same_range(a, b)
  return a.path == b.path and a.line == b.line and a.start_line == b.start_line
end

---The narrowest review comment of `path` whose marks light line `lnum`; ties go to the first listed.
---@param comments changeset.ReviewComment[]
---@param path string
---@param lnum integer
---@return changeset.ReviewComment?
function M.at(comments, path, lnum)
  local narrowest, narrowest_width
  for _, comment in ipairs(comments) do
    local first, last = M.first(comment), comment.line
    if
      comment.path == path
      and first
      and last
      and first <= lnum
      and lnum <= last
      and not (narrowest_width and last - first >= narrowest_width)
    then
      narrowest, narrowest_width = comment, last - first
    end
  end
  return narrowest
end

---"line 4", "lines 3-5" for a range, or "whole file" for none.
---@param first integer?
---@param last integer?
---@return string
function M.lines_label(first, last)
  if not (first and last) then
    return "whole file"
  end
  return first < last and ("lines %d-%d"):format(first, last) or ("line %d"):format(last)
end

---`comment`'s lines: "4", "3-5" for a range, nil for a whole file's.
---@param comment changeset.ReviewComment
---@return string?
function M.span(comment)
  if not comment.line then
    return nil
  end
  local first = M.first(comment)
  return first < comment.line and ("%d-%d"):format(first, comment.line) or tostring(comment.line)
end

---Where `comment` sits, as the Comments row names it: "a.lua:4", "a.lua:3-5" for a range, or "a.lua" for the
---whole file.
---@param comment changeset.ReviewComment
---@return string
function M.location(comment)
  local span = M.span(comment)
  return span and comment.path .. ":" .. span or comment.path
end

---Where `comment` sits, for a sentence: "line 4 of a.lua", or "the whole of a.lua".
---@param comment changeset.ReviewComment
---@return string
function M.place(comment)
  if not comment.line then
    return "the whole of " .. comment.path
  end
  return ("%s of %s"):format(M.lines_label(M.first(comment), comment.line), comment.path)
end

---Where line `lnum` stands after the changes `hunks`, `vim.text.diff` indices, made: as a range's first line and as
---its last. They differ only for a deleted line, the first going to the line after the deletion, the last to the one
---before it. A line in a rewritten block keeps its place in the block, as far as the new block reaches.
---@param hunks [integer, integer, integer, integer][]
---@param lnum integer
---@return integer first
---@return integer last
local function map_line(hunks, lnum)
  local shift = 0
  for _, hunk in ipairs(hunks) do
    local old_start, old_count, new_start, new_count = unpack(hunk)
    -- An insertion's start is the line it follows.
    if lnum < old_start or old_count == 0 and lnum == old_start then
      break
    end
    if lnum < old_start + old_count then
      if new_count == 0 then
        return new_start + 1, new_start
      end
      local line = new_start + math.min(lnum - old_start, new_count - 1) --[[@as integer]]
      return line, line
    end
    shift = shift + new_count - old_count
  end
  return lnum + shift, lnum + shift
end

---`comment`, a line comment, on the lines `hunks` moved its own to, within `line_count`; nil when they stayed. A
---comment whose lines were all deleted goes to the line after them.
---@param comment changeset.ReviewComment
---@param hunks [integer, integer, integer, integer][]
---@param line_count integer
---@return changeset.ReviewComment?
local function moved(comment, hunks, line_count)
  local line = comment.line --[[@as integer]]
  local first = map_line(hunks, M.first(comment) --[[@as integer]])
  local _, last = map_line(hunks, line)
  last = math.min(math.max(first, last), line_count)
  first = math.min(first, line_count)
  if first == M.first(comment) and last == line then
    return nil
  end
  local to = vim.deepcopy(comment)
  to.line, to.start_line = last, first < last and first or nil
  return to
end

---`lines` as one text, each line ended, as `vim.text.diff` takes it.
---@param lines string[]
---@return string
local function text(lines)
  return table.concat(lines, "\n") .. "\n"
end

---Each of `comments`, line comments of a file, that the edits from lines `before` to lines `after` moved, with the
---lines they moved to.
---@param before string[]
---@param after string[]
---@param comments changeset.ReviewComment[]
---@return changeset.ReviewCommentMove[]
function M.moves(before, after, comments)
  local hunks = vim.text.diff(text(before), text(after), { result_type = "indices", algorithm = "histogram" })
  ---@cast hunks [integer, integer, integer, integer][]
  local found = {}
  for _, comment in ipairs(comments) do
    local to = moved(comment, hunks, #after)
    if to then
      found[#found + 1] = { from = comment, to = to }
    end
  end
  return found
end

---Where `comment` starts against line `lnum` of `path`, `count` lines long, in the order of `before`: 1 after, -1
---before, 0 there. A comment past the end starts on the last line, where a jump to it lands.
---@param comment changeset.ReviewComment
---@param path string
---@param lnum integer
---@param count integer
---@return integer
local function side(comment, path, lnum, count)
  if comment.path ~= path then
    return comment.path > path and 1 or -1
  end
  local first = math.min(M.first(comment) or 0, count)
  return first > lnum and 1 or first < lnum and -1 or 0
end

---Index of the comment `step` away from the cursor in `comments`, and whether it wrapped. From no file, the first
---or last.
---@param comments changeset.ReviewComment[]
---@param path string?
---@param lnum integer
---@param count integer `path`'s line count.
---@param step 1|-1
---@return integer index, boolean wrapped
local function neighbour(comments, path, lnum, count, step)
  local from, to = 1, #comments
  if step == -1 then
    from, to = to, from
  end
  if not path then
    return from, false
  end
  for i = from, to, step do
    if side(assert(comments[i], "changeset: stepped past the review comments"), path, lnum, count) == step then
      return i, false
    end
  end
  return from, true
end

---The comment `count` steps from line `at.lnum` of `at.path` among `comments`, sorted by `before`, wrapping at
---either end; from no file, the first or last.
---@param comments changeset.ReviewComment[]
---@param at { path: string?, lnum: integer, lines: integer } `lines`: the file's line count.
---@param count integer Down for positive.
---@return integer index
---@return boolean wrapped
function M.step(comments, at, count)
  local step = count > 0 and 1 or -1
  local i, wrapped = neighbour(comments, at.path, at.lnum, at.lines, step)
  for _ = 2, math.abs(count) do
    i = i + step
    if i < 1 or i > #comments then
      i, wrapped = (i - 1) % #comments + 1, true
    end
  end
  return i, wrapped
end

return M
