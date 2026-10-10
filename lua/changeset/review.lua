---The gutter's base: points gitsigns' base at this branch's fork point from the
---branch it was created from, else from its open PR's target branch, else from the
---default branch, so the gutter marks everything the branch changed rather than just
---uncommitted work. The default branch is measured against its own remote, so its
---unpushed commits show. It measures in the repository of the buffer gitsigns last
---updated. A stacked branch starts on its parent's base; one with no parent, whose PR gh
---has not named yet, starts on the default-branch base and moves once the answer lands.
---Requiring it registers nothing; `activate()` starts the watcher that keeps buffers on
---that base as the repository and branch change.
local Git = require("changeset.git")
local fork_point = require("changeset.fork_point")

local M = {}

---@type string? Branch the base was last resolved for.
local applied

---@type string? Base every buffer should diff against; nil is the index.
local want

---@type string? Toplevel of the repository the base acts on.
local toplevel

---@type table<string, true> Bases `apply` has set.
local ours = {}

---@type table<integer, string|false> Buffers with a move in flight, by target; false is the index.
local moving = {}

---@type fun(point: changeset.ForkPoint)? Continues `enable` once gh answers; `apply` drops it.
local waiting

---Whether a base is applied (its intent; gitsigns may still be catching up).
---@return boolean
local function is_on()
  return want ~= nil
end

-- Reaches into gitsigns internals: its buffer cache, git_obj.revision
-- and repo.toplevel, and non-global change_base reading current_buf() before it
-- yields.

---Whether this file may move a buffer's base: buffers of another repository,
---fugitive/gitsigns blob buffers and bases set by hand are left alone. A
---per-buffer reset to the index is indistinguishable from the default, so the
---watcher reclaims it.
---@param buf integer
---@param git_obj Gitsigns.GitObj
---@return boolean
local function owned(buf, git_obj)
  return git_obj.repo.toplevel == toplevel
    and not vim.api.nvim_buf_get_name(buf):match("^%a+://")
    and (git_obj.revision == nil or ours[git_obj.revision] == true)
end

---Move one buffer onto `want`, unless a move there is already in flight.
---@param buf integer
---@param done fun(err: string?)?
local function move(buf, done)
  local target = want or false
  if moving[buf] == target then
    return done and done()
  end
  moving[buf] = target
  vim.api.nvim_buf_call(buf, function()
    require("gitsigns").change_base(want, false, function(err)
      if moving[buf] == target then
        moving[buf] = nil
      end
      if done then
        done(err)
      end
    end)
  end)
end

---Report a base change that failed to land; one that did is silent.
---@param err string?
local function report(err)
  if err then
    vim.notify("Changeset: could not set the gutter's base: " .. err, vim.log.levels.ERROR)
  end
end

---Move buffers that missed the base, such as ones attached while it changed.
local function reconcile()
  for buf, bcache in pairs(require("gitsigns.cache").cache) do
    if bcache.git_obj.revision ~= want and owned(buf, bcache.git_obj) then
      move(buf, report)
    end
  end
end

---Point every owned buffer at `base`; `reconcile` moves ones attached later.
---@param base string?
---@param done fun(err: string?)? Called once every move has landed, with the first error.
local function apply(base, done)
  waiting = nil
  want = base
  if base then
    ours[base] = true
  end
  local left, first = 1, nil
  local function landed(err)
    first = first or err
    left = left - 1
    if left == 0 and done then
      done(first)
    end
  end
  for buf, bcache in pairs(require("gitsigns.cache").cache) do
    if owned(buf, bcache.git_obj) then
      -- The repo watcher's refresh reads this field right after GitSignsUpdate
      -- and writes it back when it lands; setting it now makes that refresh land
      -- on the new base.
      bcache.git_obj.revision = base
      left = left + 1
      move(buf, landed)
    end
  end
  landed()
end

---Diff against the fork point, and follow gh's answer when it is still on its way.
---@param root string
---@param branch string
local function enable(root, branch)
  local function warn_skipped(point)
    if point.skipped then
      vim.notify(
        "Changeset: no merge base with " .. point.skipped .. "; diffing against " .. point.default_branch,
        vim.log.levels.WARN
      )
    end
  end
  local point, asking = fork_point.get(root, branch)
  if not point then
    -- On the default branch the index is the quiet fallback; elsewhere the missing base is worth a warning.
    if is_on() then
      apply(nil)
    end
    if branch ~= Git.default_base(root) then
      vim.notify("Changeset: no merge base with the default branch", vim.log.levels.WARN)
    end
    return
  end
  apply(point.base, report)
  if not asking then
    return warn_skipped(point)
  end
  waiting = function(answer)
    if answer.against ~= answer.default_branch and answer.base ~= want then
      return apply(answer.base, report)
    end
    warn_skipped(answer)
  end
end

---Follow a change of repository or branch. Re-resolves the base on each change, since
---the fork point belongs to the branch left behind.
---@param root string
---@param branch string
local function sync(root, branch)
  if root == toplevel and branch == applied then
    return
  end
  toplevel, applied = root, branch
  enable(root, branch)
end

---The repository and branch gitsigns published for `buf`, attached or not.
---@param buf integer
---@return string? root nil when gitsigns published nothing for `buf` or it is on no branch.
---@return string? branch
local function tracked(buf)
  -- gitsigns publishes the status before it caches the buffer, so this reads the
  -- status. Its `root` is `git_obj.repo.toplevel`, the spelling `owned()` compares.
  local status = vim.b[buf].gitsigns_status_dict
  -- A detached HEAD, such as each commit of a rebase, is no new branch, so what is applied stays. Asked of git's own
  -- files: gitsigns publishes it as a short hash, which a branch may be named like.
  local detached = status and status.root and Git.detached(status.root)
  if status and status.root and status.head and status.head ~= "" and not detached then
    return status.root, status.head
  end
end

---@param root string
---@param branch string
---@param point changeset.ForkPoint
local function on_answer(root, branch, point)
  if waiting and root == toplevel and branch == applied then
    local continue = waiting
    waiting = nil
    continue(point)
  end
end

---Handles one gitsigns update: follows the buffer's branch, then moves any buffer that missed the base.
---@param args vim.api.keyset.create_autocmd.callback_args
local function on_update(args)
  local root, branch
  if args.data then
    root, branch = tracked(args.data.buffer)
  end
  if root and branch then
    sync(root, branch)
  end
  reconcile()
end

---Start the watcher that keeps every buffer on the branch's base as the repository or branch changes.
---Safe to call more than once. `event`, the update that starts it, is handled here too: the watcher's
---autocmd is created during that update, so it need not hear it.
---@param event vim.api.keyset.create_autocmd.callback_args?
function M.activate(event)
  fork_point.subscribe(on_answer)
  -- gitsigns republishes a buffer's branch on every sign refresh, including after
  -- a checkout made outside Neovim, so this doubles as a repository- and
  -- branch-change hook, and each event also moves buffers that missed the base.
  -- Its cwd-wide sibling event carries no buffer and is skipped: that watcher
  -- never starts in a worktree, where `.git` is a file rather than a directory.
  vim.api.nvim_create_autocmd("User", {
    group = vim.api.nvim_create_augroup("changeset.review", { clear = true }),
    pattern = "GitSignsUpdate",
    desc = "changeset: keep buffers on the branch's base as the repository or branch changes",
    callback = on_update,
  })
  if event then
    on_update(event)
  end
end

return M
