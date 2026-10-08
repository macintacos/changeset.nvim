---The text a Review is pasted as: a block per review comment, its backticked place and its feedback.
local review_comment = require("changeset.review_comment")

local M = {}

---One comment's block: its absolute path and line range in backticks, then `Feedback:` and its body.
---@param repository string
---@param comment changeset.ReviewComment
---@return string
local function block(repository, comment)
  local place = vim.fs.joinpath(repository, comment.path)
  local last = comment.line
  if last then
    local first = review_comment.first(comment)
    place = place .. (first == last and (":L%d"):format(last) or (":L%d-L%d"):format(first, last))
  end
  return ("`%s`\nFeedback: %s"):format(place, (comment.body:gsub("%s+$", "")))
end

---The text a review is pasted as: a block per comment, its backticked `path:Lfirst-Llast` then `Feedback:` and its
---body, in `review_comment.before`'s order, a blank line between blocks.
---@param repository string
---@param comments changeset.ReviewComment[]
---@return string
function M.text(repository, comments)
  local sorted = vim.list_slice(comments)
  table.sort(sorted, review_comment.before)
  return table.concat(
    vim.tbl_map(function(comment)
      return block(repository, comment)
    end, sorted),
    "\n\n"
  )
end

return M
