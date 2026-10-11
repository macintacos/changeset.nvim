---The gutter's base: points gitsigns' base at this branch's fork point from the
---branch it was created from, else from its open PR's target branch, else from the
---default branch, so the gutter marks everything the branch changed rather than just
---uncommitted work. The default branch is measured against its own remote, so its
---unpushed commits show. It measures in the repository of the buffer gitsigns last
---updated. A stacked branch starts on its parent's base; one with no parent, whose PR gh
---has not named yet, starts on the default-branch base and moves once the answer lands.
---The base is measured again as HEAD moves on the branch and as Neovim regains focus, and
---follows any fork point measured anew for it, the sidebar's included. Without one it is the
---index, quietly: nobody asked for the gutter's base. Requiring it registers nothing;
---`activate()` starts the watcher that keeps buffers on that base.
local Git = require("changeset.git")
local fork_point = require("changeset.fork_point")

local M = {}

---@type string? Branch the base was last resolved for.
local applied

---@type string? HEAD's commit the base was last resolved for.
local applied_head

---gitsigns' repository objects whose gitdir watcher this hears.
---@type table<Gitsigns.Repo, true?>
local watched = setmetatable({}, { __mode = "k" })

---@type string? Base every buffer should diff against; nil is the index.
local want

---@type string? Toplevel of the repository the base acts on.
local toplevel

---@type table<string, true> Bases `apply` has set.
local ours = {}

---@type table<integer, string|false> Buffers with a move in flight, by target; false is the index.
local moving = {}

-- Reaches into gitsigns internals: its buffer cache, git_obj.revision,
-- repo.toplevel and repo.head_oid, and non-global change_base reading current_buf()
-- before it yields.

---Whether this file may move a buffer's base: buffers of another repository,
---fugitive/gitsigns blob buffers and bases set by hand are left alone. A
---per-buffer reset to the index is indistinguishable from the default, so the
---watcher reclaims it. gitsigns keeps a read that a move overtakes, so a buffer
---it has no text for waits for its next update.
---@param buf integer
---@param bcache Gitsigns.CacheEntry
---@return boolean
local function owned(buf, bcache)
  local git_obj = bcache.git_obj
  return git_obj.repo.toplevel == toplevel
    and not vim.api.nvim_buf_get_name(buf):match("^%a+://")
    and (git_obj.revision == nil or ours[git_obj.revision] == true)
    and bcache.compare_text ~= nil
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
    if bcache.git_obj.revision ~= want and owned(buf, bcache) then
      move(buf, report)
    end
  end
end

---Point every owned buffer at `base`; `reconcile` moves ones attached later.
---@param base string?
---@param done fun(err: string?)? Called once every move has landed, with the first error.
local function apply(base, done)
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
    if owned(buf, bcache) then
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

---Move onto `point`, a fork point measured for `branch` at `root`, while that is still what the base is resolved for;
---without one, onto the index.
---@param root string
---@param branch string
---@param point changeset.ForkPoint?
local function follow(root, branch, point)
  local base = point and point.base
  if root == toplevel and branch == applied and base ~= want then
    apply(base, report)
  end
end

---Measure the fork point again without blocking, then follow it. gh is asked only as the branch changes, and again as
---HEAD moves once it has named a PR, never each time the remote branch may have moved.
---@param root string
---@param branch string
local function remeasure(root, branch)
  fork_point.measure_async(root, branch, function(point)
    follow(root, branch, point)
  end)
end

---Follow a change of repository or branch, re-resolving the base, since the fork point belongs to the branch left
---behind.
---@param root string
---@param branch string
local function sync(root, branch)
  if root == toplevel and branch == applied then
    return
  end
  toplevel, applied, applied_head = root, branch, select(2, Git.head(root))
  follow(root, branch, (fork_point.get(root, branch)))
end

---Follow HEAD moving to `head` on the branch the base is resolved for, as a pull, a commit or a rebase moves it: the
---fork point can move with it, and the PR can have been retargeted, so both are asked again.
---@param head string?
local function moved(head)
  if head and head ~= applied_head and toplevel and applied then
    applied_head = head
    fork_point.recheck(toplevel, applied)
    remeasure(toplevel, applied)
  end
end

---Hear `repo`'s gitdir watcher, which ticks as HEAD moves. gitsigns publishes no update for a move that leaves every
---open buffer's signs as they were.
---@param repo Gitsigns.Repo
local function watch(repo)
  if watched[repo] or not repo:has_watcher() then
    return
  end
  watched[repo] = true
  -- After gitsigns' own callback, which reads HEAD again. A checkout is the branch's update to follow, not a move.
  repo:on_update(function()
    if repo.toplevel == toplevel and repo.abbrev_head == applied then
      moved(repo.head_oid)
    end
  end)
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

---Handles one gitsigns update: follows the buffer's branch, hears its repository's watcher, then moves any buffer that
---missed the base.
---@param args vim.api.keyset.create_autocmd.callback_args
local function on_update(args)
  local buf = args.data and args.data.buffer
  local root, branch
  if buf then
    root, branch = tracked(buf)
    local bcache = require("gitsigns.cache").cache[buf]
    if bcache then
      watch(bcache.git_obj.repo)
    end
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
  fork_point.subscribe(follow)
  local group = vim.api.nvim_create_augroup("changeset.review", { clear = true })
  -- gitsigns republishes a buffer's branch on every sign refresh, including after
  -- a checkout made outside Neovim, so this doubles as a repository- and
  -- branch-change hook, and each event also moves buffers that missed the base.
  -- Its cwd-wide sibling event carries no buffer, so it follows no branch but still moves
  -- buffers that missed the base. Branches follow from buffer events because that watcher
  -- never starts in a worktree, where `.git` is a file rather than a directory.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "GitSignsUpdate",
    desc = "changeset: keep buffers on the branch's base as the repository, branch or HEAD changes",
    callback = on_update,
  })
  -- Fires: Neovim regaining focus, as after a push or fetch made outside it. Either moves the remote branch the base
  -- can be measured against, which gitsigns' watcher doesn't see.
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    desc = "changeset: measure the branch's base again once Neovim regains focus",
    callback = function()
      if toplevel and applied then
        remeasure(toplevel, applied)
      end
    end,
  })
  if event then
    on_update(event)
  end
end

return M
