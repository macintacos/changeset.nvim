---The text a Review is pasted as: a block per review comment, its place, its lines fenced and its body.
local review_comment = require("changeset.review_comment")

local M = {}

---Lines `first` to `last` of a file; nil when they can't all be read.
---@alias changeset.review_text.ReadLines fun(path: string, first: integer, last: integer): string[]?

---The longest run of backticks in `lines`, at least 2, so a fence one longer is at least 3.
---@param lines string[]
---@return integer
local function longest_backticks(lines)
  local longest = 2
  for _, line in ipairs(lines) do
    for run in line:gmatch("`+") do
      longest = math.max(longest, #run)
    end
  end
  return longest
end

---One comment's block: its place by absolute path, its lines fenced in the file's language, and its body. A whole
---file's quotes none.
---@param repository string
---@param comment changeset.ReviewComment
---@param read changeset.review_text.ReadLines
---@return string
local function block(repository, comment, read)
  local parts = { vim.fs.joinpath(repository, review_comment.location(comment)) }
  local last = comment.line
  local lines = last and read(comment.path, review_comment.first(comment) --[[@as integer]], last)
  if lines then
    local fence = ("`"):rep(longest_backticks(lines) + 1)
    parts[#parts + 1] = fence .. (vim.filetype.match({ filename = comment.path }) or "")
    vim.list_extend(parts, lines)
    parts[#parts + 1] = fence
  end
  parts[#parts + 1] = (comment.body:gsub("%s+$", ""))
  return table.concat(parts, "\n")
end

---The text a review is pasted as: a block per comment, in `review_comment.before`'s order, a blank line
---between blocks.
---@param repository string
---@param comments changeset.ReviewComment[]
---@param read changeset.review_text.ReadLines
---@return string
function M.text(repository, comments, read)
  local sorted = vim.list_slice(comments)
  table.sort(sorted, review_comment.before)
  return table.concat(
    vim.tbl_map(function(comment)
      return block(repository, comment, read)
    end, sorted),
    "\n\n"
  )
end

return M
