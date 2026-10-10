---`:Changeset base`: compares the current branch against a ref of the user's choosing, named or picked from its
---branches, or against the base it guesses again.
local Git = require("changeset.git")
local Paths = require("changeset.paths")
local fork_point = require("changeset.fork_point")

local M = {}

-- No branch is named this: a ref name can't hold a space.
local GUESS = "(guess again)"

---The current buffer's repository and the branch checked out there, or nothing, having said why.
---@return string? root
---@return string? branch
local function current()
  local root = Paths.root(0)
  local branch = Git.head(root)
  if branch and branch ~= "HEAD" then
    return root, branch
  end
  vim.notify("Changeset: a base is set per branch, and HEAD is on none", vim.log.levels.ERROR)
end

---Measure `branch` at `root` from `ref`, or guess again when it is nil.
---@param root string
---@param branch string
---@param ref string?
local function pin(root, branch, ref)
  if ref and not Git.merge_base(root, ref) then
    return vim.notify(("Changeset: HEAD shares no history with %s"):format(ref), vim.log.levels.ERROR)
  end
  if not fork_point.pin(root, branch, ref) then
    vim.notify("Changeset: could not save the base", vim.log.levels.ERROR)
  end
end

---Compare the current branch against `ref`, a branch, tag or commit, until it is reset.
---@param ref string
function M.set(ref)
  local root, branch = current()
  if root and branch then
    pin(root, branch, ref)
  end
end

---Compare the current branch against the base it guesses again.
function M.reset()
  local root, branch = current()
  if root and branch then
    pin(root, branch, nil)
  end
end

---Pick a branch to compare the current branch against, or, while one is set, to guess again.
function M.pick()
  local root, branch = current()
  if not (root and branch) then
    return
  end
  local items = vim.tbl_filter(function(name)
    return name ~= branch
  end, Git.branches(root))
  if fork_point.pinned(root, branch) then
    table.insert(items, 1, GUESS)
  end
  vim.ui.select(items, { prompt = ("Compare %s against"):format(branch) }, function(choice)
    if choice then
      pin(root, branch, choice ~= GUESS and choice or nil)
    end
  end)
end

return M
