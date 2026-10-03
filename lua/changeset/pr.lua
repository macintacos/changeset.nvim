---`:Changeset pr`'s verbs: start and abandon the pending review on the branch's open PR.
local Paths = require("changeset.paths")
local build = require("changeset.build")
local pending_review = require("changeset.pending_review")
local pending_state = require("changeset.pending_state")

local M = {}

---The repository to act on: the tree's when the command runs from the sidebar, whose own buffer
---names none, else the current buffer's, as `build` resolves it.
---@return string
local function root()
  local tree = build.current()
  if vim.bo.filetype == "changeset" and tree then
    return tree.root
  end
  return Paths.root(0)
end

---@param count integer
---@return string
local function review_comments(count)
  return count .. (count == 1 and " review comment" or " review comments")
end

---Starts a pending review on the branch's open PR, unless one is already under way.
function M.start()
  local at = root()
  pending_state.fetch(at, function(err, found)
    if not found then
      return vim.notify("Changeset: can't start a pending review: " .. tostring(err), vim.log.levels.WARN)
    end
    if found.review then
      return vim.notify(
        ("Changeset: a pending review is already under way on #%d"):format(found.pr.number),
        vim.log.levels.INFO
      )
    end
    pending_review.start(found.pr.id, function(start_err)
      if start_err then
        vim.notify("Changeset: can't start a pending review: " .. start_err, vim.log.levels.ERROR)
      else
        vim.notify(("Changeset: started a pending review on #%d"):format(found.pr.number), vim.log.levels.INFO)
      end
      pending_state.fetch(at)
    end)
  end)
end

---Asks, then deletes the pending review on the branch's open PR and every review comment in it.
function M.abandon()
  local at = root()
  pending_state.fetch(at, function(err, found)
    if not found then
      return vim.notify("Changeset: can't abandon a pending review: " .. tostring(err), vim.log.levels.WARN)
    end
    local number, review = found.pr.number, found.review
    if not review then
      return vim.notify(("Changeset: no pending review on #%d"):format(number), vim.log.levels.INFO)
    end
    local question = ("Abandon the pending review on #%d and its %s?"):format(number, review_comments(#review.comments))
    -- No is 2 and <Esc> is 0: anything but Yes changes nothing.
    if vim.fn.confirm(question, "&Yes\n&No", 2) ~= 1 then
      return
    end
    pending_review.delete(review.id, function(delete_err)
      if delete_err then
        vim.notify("Changeset: can't abandon the pending review: " .. delete_err, vim.log.levels.ERROR)
      else
        vim.notify(("Changeset: abandoned the pending review on #%d"):format(number), vim.log.levels.INFO)
      end
      pending_state.fetch(at)
    end)
  end)
end

return M
