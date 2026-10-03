---Where the branch forked: the default branch's fork point, or its open PR's target's when stacked.
local Git = require("changeset.git")

local M = {}

---@class changeset.ForkPoint
---@field base string Commit HEAD forked at.
---@field ref string Ref whose history holds `base`, e.g. "origin/trunk".
---@field against string Branch `base` was measured against: the default branch, or the open PR's target.
---@field default_branch string The repository's default branch, whatever `against` is.
---@field pr integer? The open PR's number, while `base` is measured against its target.
---@field skipped string? The open PR's target when HEAD shares no fork point with it, so `base` stayed on the default branch's.

---Each open PR, by `root .. "\n" .. branch`, kept for the session.
---An answer of no PR is not kept, so a PR opened since is found.
---@type table<string, changeset.Pr>
local targets = {}

---The point measured when gh was asked, by the same key, while it is being asked.
---@type table<string, changeset.ForkPoint>
local asking = {}

---@type table<fun(root: string, branch: string, point: changeset.ForkPoint), true>
local subscribers = {}

---HEAD's fork point from `pr`'s target when the two share one, else from the default branch.
---@param root string
---@param pr changeset.Pr?
---@return changeset.ForkPoint?
local function measure(root, pr)
  local default_branch = Git.default_base(root)
  local base, ref = Git.merge_base(root, default_branch)
  if not base then
    return
  end
  local point = { base = base, ref = ref, against = default_branch, default_branch = default_branch }
  if pr then
    local stacked, stacked_ref = Git.merge_base(root, pr.target)
    if stacked then
      point.base, point.ref, point.against, point.pr = stacked, stacked_ref, pr.target, pr.number
    else
      point.skipped = pr.target
    end
  end
  return point
end

---The fork point of `branch` at `root`. Asks gh about its PR unless gh has named a target or is being asked.
---@param root string Repository to measure in.
---@param branch string The branch checked out at `root`.
---@return changeset.ForkPoint? point nil when HEAD shares no fork point with the default branch.
---@return boolean asking Whether gh is still being asked, so subscribers will hear its answer.
function M.get(root, branch)
  local key = root .. "\n" .. branch
  local point = measure(root, targets[key])
  if not point then
    return nil, false
  end
  if targets[key] or asking[key] then
    return point, asking[key] ~= nil
  end
  asking[key] = point
  Git.pr(root, function(_, pr)
    local heard = asking[key]
    asking[key] = nil
    if pr then
      targets[key] = pr
      -- HEAD can have moved by the time gh answers; subscribers still need a point.
      heard = measure(root, targets[key]) or heard
    end
    for fn in pairs(subscribers) do
      fn(root, branch, heard)
    end
  end)
  return point, true
end

---Hear every gh answer, for any repository and branch. Subscribing `fn` again does nothing.
---@param fn fun(root: string, branch: string, point: changeset.ForkPoint) Called with the fork point that answer leaves.
function M.subscribe(fn)
  subscribers[fn] = true
end

return M
