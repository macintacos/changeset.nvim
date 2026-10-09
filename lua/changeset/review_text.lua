---The text a Review is pasted as: the configured header, a block per review comment, then the footer.
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

---The text a review is pasted as: `framing`'s header, a block per comment in `review_comment.before`'s order, then its
---footer, a blank line apart; a blank header or footer adds nothing.
---@param repository string
---@param comments changeset.ReviewComment[]
---@param framing changeset.Config.Review
---@return string
function M.text(repository, comments, framing)
  local sorted = vim.list_slice(comments)
  table.sort(sorted, review_comment.before)
  local blocks = table.concat(
    vim.tbl_map(function(comment)
      return block(repository, comment)
    end, sorted),
    "\n\n"
  )
  local parts = { vim.trim(framing.header), blocks, vim.trim(framing.footer) }
  return table.concat(
    vim.tbl_filter(function(part)
      return part ~= ""
    end, parts),
    "\n\n"
  )
end

return M
