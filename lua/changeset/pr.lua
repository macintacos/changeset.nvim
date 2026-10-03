---`:Changeset pr`'s verbs: start and abandon the pending review on the branch's open PR, and delete one of its review comments.
local Paths = require("changeset.paths")
local build = require("changeset.build")
local pending_review = require("changeset.pending_review")
local pending_state = require("changeset.pending_state")
local window = require("changeset.window")

local M = {}

---The repository to act on: the tree's when the command runs from the sidebar, whose own buffer
---names none, else the current buffer's, as `build` resolves it.
---@return string
local function root()
  local tree = build.current()
  if window.is_focused() and tree then
    return tree.root
  end
  return Paths.root(0)
end

---@param count integer
---@return string
local function review_comments(count)
  return count .. (count == 1 and " review comment" or " review comments")
end

---@param level integer
---@param text string
local function say(level, text, ...)
  vim.notify("Changeset: " .. text:format(...), level)
end

---Finds the branch's PR and pending review and hands them to `act`, which mutates and calls
---`done`; `done` reports and refetches, so the header always follows a mutation.
---@param verb string Reads between "can't" and "a pending review": "start", "abandon", "delete a review comment from".
---@param act fun(found: changeset.pending_review.Found, done: fun(err: string?, did: string))
local function on_pr(verb, act)
  local repository = root()
  pending_state.fetch(repository, function(err, found)
    if not found then
      return say(vim.log.levels.WARN, "can't %s a pending review: %s", verb, err)
    end
    act(found, function(act_err, did)
      if act_err then
        say(vim.log.levels.ERROR, "can't %s the pending review: %s", verb, act_err)
      else
        say(vim.log.levels.INFO, "%s the pending review on #%d", did, found.pr.number)
      end
      pending_state.fetch(repository)
    end)
  end)
end

---Starts a pending review on the branch's open PR, unless one is already under way.
function M.start()
  on_pr("start", function(found, done)
    if found.review then
      return say(vim.log.levels.INFO, "a pending review is already under way on #%d", found.pr.number)
    end
    pending_review.start(found.pr.id, function(err)
      done(err, "started")
    end)
  end)
end

---Asks, then deletes the pending review on the branch's open PR and every review comment in it.
function M.abandon()
  on_pr("abandon", function(found, done)
    local number, review = found.pr.number, found.review
    if not review then
      return say(vim.log.levels.INFO, "no pending review on #%d", number)
    end
    local question = ("Abandon the pending review on #%d and its %s?"):format(number, review_comments(#review.comments))
    -- Needs <CR>, so keys typed while gh was answering cancel rather than confirm.
    local reply = vim.trim(vim.fn.input({ prompt = question .. " [y/N] ", cancelreturn = "" })):lower()
    if reply ~= "y" and reply ~= "yes" then
      return
    end
    pending_review.delete(review.id, function(err)
      done(err, "abandoned")
    end)
  end)
end

---Deletes the review comment on the cursor's line from the pending review on the branch's open PR.
function M.delete()
  -- Extmarks move with edits while review comment lines don't, so a modified buffer could delete the wrong one.
  if vim.bo.modified then
    return say(vim.log.levels.WARN, "save the file first: marks move with unsaved edits, review comments don't")
  end
  local path = vim.fs.relpath(root(), vim.fs.normalize(vim.api.nvim_buf_get_name(0)))
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  on_pr("delete a review comment from", function(found, done)
    if not found.review then
      return say(vim.log.levels.INFO, "no pending review on #%d", found.pr.number)
    end
    local comment = path and require("changeset.review_comments").at(found.review.comments, path, lnum)
    if not comment then
      return say(vim.log.levels.INFO, "no review comment on line %d", lnum)
    end
    pending_review.delete_comment(comment.id, function(err)
      done(err, "deleted a review comment from")
    end)
  end)
end

return M
