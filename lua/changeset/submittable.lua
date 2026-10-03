---Which pending review submits GitHub takes.

local M = {}

-- Keep in sync with doc/agents/github-reviews.md, "Submitting".
---@param submission { event: changeset.pending_review.Event, body: string? }
---@param comment_count integer Review comments on the pending review.
---@return string? reason Why GitHub would refuse the submit, or nil when it takes it.
function M.refusal(submission, comment_count)
  if submission.event == "COMMENT" and comment_count == 0 and not submission.body then
    return "a comment with no review comments needs a body"
  end
end

return M
