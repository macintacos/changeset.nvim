---Where the branch forked: the default branch's fork point, or its open PR's target's when stacked.
local Git = require("changeset.git")

local M = {}

---@class changeset.ForkPoint
---@field base string Commit HEAD forked at.
---@field ref string Ref whose history holds `base`, e.g. "origin/trunk".
---@field against string Branch `base` was measured against: the default branch, or the open PR's target.
---@field default_branch string
---@field pr integer? The open PR's number, while `base` is measured against its target.
---@field skipped string? The open PR's target when HEAD shares no fork point with it, so `base` stayed on the default branch's.

---@class changeset.PrTarget
---@field target string
---@field number integer

---gh's answer per `root .. "\n" .. branch`: the PR's target, kept for the session, or
---`{ asking = point }` while in flight. An answer of no PR is not kept, so a PR opened
---since is found.
---@type table<string, changeset.PrTarget | { asking: changeset.ForkPoint }>
local answers = {}

---@type table<fun(root: string, branch: string, point: changeset.ForkPoint), true>
local subscribers = {}

---@param root string
---@param pr changeset.PrTarget?
---@return changeset.ForkPoint?
local function measure(root, pr)
  local base, against, ref = Git.merge_base(root)
  if not base then
    return
  end
  local default_branch = Git.default_base(root)
  local point = { base = base, ref = ref, against = against, default_branch = default_branch }
  if pr then
    local stacked, _, stacked_ref = Git.merge_base(root, pr.target)
    if stacked then
      point.base, point.ref, point.against, point.pr = stacked, stacked_ref, pr.target, pr.number
    else
      point.skipped = pr.target
    end
  end
  return point
end

---The fork point of `branch` at `root`, asking gh about its PR when nobody has yet.
---@param root string Repository to measure in.
---@param branch string The branch checked out at `root`.
---@return changeset.ForkPoint? point nil when HEAD shares no fork point with the default branch.
---@return boolean asking Whether gh is still being asked, so subscribers will hear its answer.
function M.get(root, branch)
  local key = root .. "\n" .. branch
  local answer = answers[key]
  local point = measure(root, answer and answer.target and answer --[[@as changeset.PrTarget]])
  if not point then
    return nil, false
  end
  if answer then
    return point, answer.asking ~= nil
  end
  answers[key] = { asking = point }
  Git.pr_target(root, function(target, number)
    local heard = answers[key].asking
    answers[key] = target and { target = target, number = number } or nil
    if target then
      heard = measure(root, answers[key]) or heard
    end
    for fn in pairs(subscribers) do
      fn(root, branch, heard)
    end
  end)
  return point, true
end

---@param fn fun(root: string, branch: string, point: changeset.ForkPoint) Called each time gh answers, with the fork point that answer leaves.
function M.subscribe(fn)
  subscribers[fn] = true
end

return M
