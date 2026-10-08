---Where the branch forked: from the branch it was created from, else from its open PR's target, else from the default branch.
local Git = require("changeset.git")

local M = {}

---@class changeset.ForkPoint
---@field base string Commit HEAD forked at.
---@field ref string Ref whose history holds `base`, e.g. "origin/trunk".
---@field against string Branch `base` was measured against: the one the branch was created from, the open PR's target, or the default branch.
---@field default_branch string The repository's default branch, whatever `against` is.
---@field pr integer? The open PR's number, while `base` is measured against its target.
---@field skipped string? The open PR's target when HEAD shares no fork point with it, so `base` stayed on the default branch's.

---@class changeset.fork_point.PrTarget
---@field target string
---@field number integer

---Each open PR's target and number, by `root .. "\n" .. branch`, kept for the session.
---An answer of no PR is not kept, so a PR opened since is found.
---@type table<string, changeset.fork_point.PrTarget>
local targets = {}

---The point measured when gh was asked, by the same key, while it is being asked.
---@type table<string, changeset.ForkPoint>
local asking = {}

---@type table<fun(root: string, branch: string, point: changeset.ForkPoint), true>
local subscribers = {}

---Whether the default branch's fork point has moved past the parent's, as it does once the branch is
---rebased onto the default branch after its parent merged.
---@param root string
---@param parent_base string
---@param default_base string?
---@return boolean
local function outgrown(root, parent_base, default_base)
  return default_base ~= nil and default_base ~= parent_base and Git.is_ancestor(root, parent_base, default_base)
end

---HEAD's fork point from the branch `branch` was created from, unless the branch has outgrown it, else from
---`pr`'s target, taking each only when HEAD shares a fork point with it, else from the default branch.
---@param root string
---@param branch string
---@param pr changeset.fork_point.PrTarget?
---@return changeset.ForkPoint?
local function measure(root, branch, pr)
  local default_branch = Git.default_base(root)
  local base, ref = Git.merge_base(root, default_branch)
  local parent = Git.parent(root, branch)
  if parent and parent ~= default_branch then
    local parent_base, parent_ref = Git.merge_base(root, parent)
    if parent_base and not outgrown(root, parent_base, base) then
      -- The header names the PR only while its target forks from HEAD where `parent` does, so the PR it
      -- names is the one this diff is.
      local number = pr and (pr.target == parent or Git.merge_base(root, pr.target) == parent_base) and pr.number or nil
      return { base = parent_base, ref = parent_ref, against = parent, default_branch = default_branch, pr = number }
    end
  end
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

---Ask gh about `branch`'s PR unless gh has named a target or is being asked, once `point` is measured.
---@param root string
---@param branch string
---@param point changeset.ForkPoint?
---@return changeset.ForkPoint? point
---@return boolean asking
local function ask(root, branch, point)
  local key = root .. "\n" .. branch
  if not point then
    return nil, false
  end
  if targets[key] or asking[key] then
    return point, asking[key] ~= nil
  end
  asking[key] = point
  Git.pr_target(root, function(target, number)
    local heard = asking[key]
    asking[key] = nil
    if target then
      targets[key] = { target = target, number = number }
      -- HEAD can have moved by the time gh answers; subscribers still need a point.
      heard = measure(root, branch, targets[key]) or heard
    end
    for fn in pairs(subscribers) do
      fn(root, branch, heard)
    end
  end)
  return point, true
end

---The fork point of `branch` at `root`. Asks gh about its PR unless gh has named a target or is being asked.
---@param root string Repository to measure in.
---@param branch string The branch checked out at `root`.
---@return changeset.ForkPoint? point nil when HEAD shares no fork point with the branch it was created from or the default branch.
---@return boolean asking Whether gh is still being asked, so subscribers will hear its answer.
function M.get(root, branch)
  return ask(root, branch, measure(root, branch, targets[root .. "\n" .. branch]))
end

---`get`, measuring without blocking Neovim, and calling back on the main loop.
---@param root string
---@param branch string
---@param on_done fun(point: changeset.ForkPoint?)
function M.get_async(root, branch, on_done)
  local key = root .. "\n" .. branch
  local pr = targets[key]
  Git.async(function()
    return measure(root, branch, pr)
  end, function(point)
    -- gh answered while it measured, so `point` holds a target no longer in force.
    if targets[key] ~= pr then
      return M.get_async(root, branch, on_done)
    end
    on_done((ask(root, branch, point)))
  end)
end

---Ask gh again about the PR it named for `branch` at `root`, keeping that target in force until it answers. Subscribers
---hear the point measured from its answer, so a PR retargeted, merged or closed since is noticed.
---@param root string
---@param branch string
function M.recheck(root, branch)
  local key = root .. "\n" .. branch
  if not targets[key] or asking[key] then
    return
  end
  Git.pr_target(root, function(target, number)
    targets[key] = target and { target = target, number = number } or nil
    local pr = targets[key]
    Git.async(function()
      return measure(root, branch, pr)
    end, function(point)
      if not point then
        return
      end
      for fn in pairs(subscribers) do
        fn(root, branch, point)
      end
    end)
  end)
end

---Hear every gh answer, for any repository and branch. Subscribing `fn` again does nothing.
---@param fn fun(root: string, branch: string, point: changeset.ForkPoint) Called with the fork point that answer leaves.
function M.subscribe(fn)
  subscribers[fn] = true
end

return M
