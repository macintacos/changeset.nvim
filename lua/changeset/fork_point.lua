---Where the branch forked: from a base set by hand, else from the branch it was created from, else from its open PR's
---target, else from the default branch.
local Git = require("changeset.git")
local jsonfile = require("changeset.jsonfile")

local M = {}

---@alias changeset.RefKind "branch"|"tag"|"commit"

---@class changeset.ForkPoint
---@field base string Commit HEAD forked at.
---@field ref string Ref whose history holds `base`, e.g. "origin/trunk".
---@field kind changeset.RefKind What `ref` names; only a ref set by hand is ever not a branch.
---@field against string What `base` was measured against: the ref set by hand, the branch the branch was created from, the open PR's target, or the default branch.
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

---The point last measured while gh is being asked, by the same key.
---@type table<string, changeset.ForkPoint>
local asking = {}

---Keys `recheck` is asking gh about.
---@type table<string, true>
local rechecking = {}

---@type table<fun(root: string, branch: string, point: changeset.ForkPoint), true>
local subscribers = {}

---Where the bases set by hand are kept, by root and then by branch. Under `state`: losing it loses a choice.
---@return string
local function pins_path()
  return vim.fs.joinpath(vim.fn.stdpath("state"), "changeset", "bases.json")
end

---The ref set by hand for `branch` at `root`, if any.
---@param root string
---@param branch string
---@return string?
local function pinned(root, branch)
  local repo = jsonfile.read(pins_path())[root]
  local ref = type(repo) == "table" and repo[branch]
  return type(ref) == "string" and ref or nil
end

---`pr`'s number while its target is `against`, or forks from HEAD at `base` as `against` does, so the PR the header
---names is the diff it shows.
---@param root string
---@param pr changeset.fork_point.PrTarget?
---@param against string
---@param base string
---@return integer?
local function pr_number(root, pr, against, base)
  return pr and (pr.target == against or Git.merge_base(root, pr.target) == base) and pr.number or nil
end

---Whether the default branch's fork point has moved past the parent's, as it does once the branch is
---rebased onto the default branch after its parent merged.
---@param root string
---@param parent_base string
---@param default_base string?
---@return boolean
local function outgrown(root, parent_base, default_base)
  return default_base ~= nil and default_base ~= parent_base and Git.is_ancestor(root, parent_base, default_base)
end

---HEAD's fork point from the ref set by hand for `branch`, else from the branch it was created from, unless the branch
---has outgrown it, else from `pr`'s target, taking each only when HEAD shares a fork point with it, else from the
---default branch.
---@param root string
---@param branch string
---@param pr changeset.fork_point.PrTarget?
---@return changeset.ForkPoint?
local function measure(root, branch, pr)
  local default_branch = Git.default_base(root)
  local by_hand = pinned(root, branch)
  if by_hand then
    local pinned_base, pinned_ref = Git.merge_base(root, by_hand)
    if pinned_base then
      local number = pr_number(root, pr, by_hand, pinned_base)
      return {
        base = pinned_base,
        ref = pinned_ref,
        kind = Git.ref_kind(root, by_hand),
        against = by_hand,
        default_branch = default_branch,
        pr = number,
      }
    end
  end
  local base, ref
  -- Its remote's fork point, so its unpushed commits show. Elsewhere the newer of the two, so a stacked branch
  -- leaves out its parent's unpushed commits.
  if branch == default_branch then
    base, ref = Git.upstream_merge_base(root, branch)
  else
    base, ref = Git.merge_base(root, default_branch)
  end
  local parent = Git.parent(root, branch)
  if parent and parent ~= default_branch then
    local parent_base, parent_ref = Git.merge_base(root, parent)
    if parent_base and not outgrown(root, parent_base, base) then
      local number = pr_number(root, pr, parent, parent_base)
      return {
        base = parent_base,
        ref = parent_ref,
        kind = "branch",
        against = parent,
        default_branch = default_branch,
        pr = number,
      }
    end
  end
  if not base then
    return
  end
  local point = { base = base, ref = ref, kind = "branch", against = default_branch, default_branch = default_branch }
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

-- How many measures `settled` takes while HEAD keeps moving under them. Its blocking callers would freeze Neovim for as
-- long as another process kept moving HEAD, and the watcher measures again on HEAD's next move anyway.
local SETTLE_TRIES = 3

---`measure`, taken again until HEAD holds still across one, up to `SETTLE_TRIES` in all, so a point never answers for a
---HEAD that moved on while it was measured, and none lands after a newer one with an older fork point.
---@param root string
---@param branch string
---@param pr changeset.fork_point.PrTarget?
---@return changeset.ForkPoint?
local function settled(root, branch, pr)
  local point
  for _ = 1, SETTLE_TRIES do
    local _, before = Git.head(root)
    point = measure(root, branch, pr)
    local _, after = Git.head(root)
    if before == after then
      break
    end
  end
  return point
end

---While gh is being asked about `branch`'s PR, have its answer carry `point`, the newest measure, rather than one HEAD
---may have moved past since gh was asked.
---@param root string
---@param branch string
---@param point changeset.ForkPoint?
---@return changeset.ForkPoint? point
local function carry(root, branch, point)
  local key = root .. "\n" .. branch
  if point and asking[key] then
    asking[key] = point
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
  if asking[key] then
    return carry(root, branch, point), true
  end
  if targets[key] then
    return point, false
  end
  asking[key] = point
  Git.pr_target(root, function(target, number)
    local heard = asking[key]
    asking[key] = nil
    if target then
      targets[key] = { target = target, number = number }
      -- HEAD can have moved by the time gh answers; subscribers still need a point.
      heard = settled(root, branch, targets[key]) or heard
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
  return ask(root, branch, settled(root, branch, targets[root .. "\n" .. branch]))
end

---Measure `branch`'s fork point at `root` without blocking Neovim, pass it through `settle`, then hand it to `on_done`
---on the main loop, then to the subscribers, so whoever else follows the branch's fork point needs no measure of its
---own.
---@param root string
---@param branch string
---@param settle fun(root: string, branch: string, point: changeset.ForkPoint?): changeset.ForkPoint?
---@param on_done fun(point: changeset.ForkPoint?)
local function measure_async(root, branch, settle, on_done)
  local key = root .. "\n" .. branch
  local pr = targets[key]
  Git.async(function()
    return settled(root, branch, pr)
  end, function(point)
    -- gh answered while it measured, so `point` holds a target no longer in force.
    if targets[key] ~= pr then
      return measure_async(root, branch, settle, on_done)
    end
    point = settle(root, branch, point)
    on_done(point)
    if point then
      for fn in pairs(subscribers) do
        fn(root, branch, point)
      end
    end
  end)
end

---`get`, measuring without blocking Neovim, and calling back on the main loop. Subscribers hear the point after
---`on_done` does.
---@param root string
---@param branch string
---@param on_done fun(point: changeset.ForkPoint?)
function M.get_async(root, branch, on_done)
  measure_async(root, branch, function(...)
    return (ask(...))
  end, on_done)
end

---`get_async` without asking gh, measured from the PR target gh last named: for measuring again as HEAD or a remote
---branch moves, which mustn't ask GitHub about a branch with no PR each time.
---@param root string
---@param branch string
---@param on_done fun(point: changeset.ForkPoint?)
function M.measure_async(root, branch, on_done)
  measure_async(root, branch, carry, on_done)
end

---Ask gh again about the PR it named for `branch` at `root`, keeping that target in force until it answers. Subscribers
---hear the point measured from its answer, so a PR retargeted, merged or closed since is noticed.
---@param root string
---@param branch string
function M.recheck(root, branch)
  local key = root .. "\n" .. branch
  if not targets[key] or asking[key] or rechecking[key] then
    return
  end
  rechecking[key] = true
  Git.pr_target(root, function(target, number, failed)
    rechecking[key] = nil
    if failed then
      return
    end
    local kept = targets[key]
    -- The same table for the same answer, so a `get_async` in flight need not measure again.
    if not (kept and kept.target == target and kept.number == number) then
      targets[key] = target and { target = target, number = number } or nil
    end
    local pr = targets[key]
    Git.async(function()
      return settled(root, branch, pr)
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

---Measure `branch` at `root` from `ref` from now on, in this session and later ones, or guess again when `ref` is nil.
---Subscribers hear the point measured from it.
---@param root string
---@param branch string
---@param ref string?
---@return boolean written false when it could not be kept, which leaves the base as it was.
function M.pin(root, branch, ref)
  local file = pins_path()
  local pins = jsonfile.read(file)
  local repo = type(pins[root]) == "table" and pins[root] or {}
  repo[branch] = ref
  pins[root] = next(repo) and repo or nil
  if not jsonfile.write(file, pins) then
    return false
  end
  measure_async(root, branch, carry, function() end)
  return true
end

---Hear every gh answer, and every fork point measured without blocking, for any repository and branch. Subscribing `fn`
---again does nothing.
---@param fn fun(root: string, branch: string, point: changeset.ForkPoint) Called with the fork point that answer leaves.
function M.subscribe(fn)
  subscribers[fn] = true
end

return M
