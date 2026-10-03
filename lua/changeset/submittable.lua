---Which pending review submits GitHub takes.

local M = {}

-- Keep in sync with doc/agents/github-reviews.md, "Submitting".

---The events GitHub takes on a PR, the one to preselect first.
---@param viewer_did_author boolean
---@return changeset.pending_review.Event[]
function M.events(viewer_did_author)
  -- GitHub refuses an approval or a change request on the viewer's own PR.
  return viewer_did_author and { "COMMENT" } or { "COMMENT", "APPROVE", "REQUEST_CHANGES" }
end

---Why GitHub would refuse `submission`; nil when it takes it.
---@param submission { event: changeset.pending_review.Event, body: string? }
---@param comment_count integer Review comments on the pending review.
---@return string? reason
function M.refusal(submission, comment_count)
  if submission.event == "COMMENT" and comment_count == 0 and not submission.body then
    return "a comment with no review comments needs a body"
  end
end

return M
