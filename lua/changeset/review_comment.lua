---What can be asked of one review comment's lines: its first line, its range, its order and its labels.

local M = {}

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

---Where `comment` sits, as the Comments row and the pasted review name it: "a.lua:4", "a.lua:3-5" for a range, or
---"a.lua" for the whole file.
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

return M
