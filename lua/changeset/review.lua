---PR Review Mode points gitsigns' base at this branch's fork point from the
---branch it was created from, else from its open PR's target branch, else from the
---default branch, so the gutter marks everything the branch changed rather than just
---uncommitted work. It measures in the repository of the buffer gitsigns last
---updated, or the one `toggle()` ran in. A stacked branch starts on its parent's base;
---one with no parent, whose PR gh has not named yet, starts on the default-branch base
---and moves once the answer lands.
---Requiring it registers nothing; once `activate()` has run, it turns itself on
---for every branch but the default, `toggle()` turns it off, and each
---repository's branch remembers that choice for the session.
local Git = require("changeset.git")
local fork_point = require("changeset.fork_point")

local M = {}

---@type table<string, true> Repository and branch pairs the mode was switched off on, keyed `root .. "\n" .. branch`.
local dismissed = {}

---@type string? Branch the base was last resolved for.
local applied

---@type string? Base every buffer should diff against; nil is the index.
local want

---@type string? Toplevel of the repository the mode acts on.
local toplevel

---@type table<string, true> Bases `apply` has set.
local ours = {}

---@type table<integer, string|false> Buffers with a move in flight, by target; false is the index.
local moving = {}

---@type fun(point: changeset.ForkPoint)? Continues `enable` once gh answers; `apply` drops it.
local waiting

---Whether the mode is on (its intent; gitsigns may still be catching up).
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
---mode reclaims it.
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

---Move buffers that missed the base, such as ones attached while it changed.
local function reconcile()
  for buf, bcache in pairs(require("gitsigns.cache").cache) do
    if bcache.git_obj.revision ~= want and owned(buf, bcache.git_obj) then
      move(buf)
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

---@param err string
local function fail(err)
  vim.notify("PR Review Mode: " .. err, vim.log.levels.ERROR)
end

---Diff against the fork point, and follow gh's answer when it is still on its way.
---@param root string
---@param branch string
---@param report boolean Announce success; failures announce regardless.
local function enable(root, branch, report)
  local function announce(target)
    if report then
      vim.notify("PR Review Mode: on (vs " .. target .. ")")
    end
  end
  local function warn_skipped(point)
    if point.skipped then
      vim.notify(
        "PR Review Mode: no merge base with " .. point.skipped .. "; diffing against " .. point.default_branch,
        vim.log.levels.WARN
      )
    end
  end
  local point, asking = fork_point.get(root, branch)
  if not point then
    if is_on() then
      apply(nil)
    end
    return vim.notify("PR Review Mode: no merge base with the default branch", vim.log.levels.WARN)
  end
  -- The first notice waits on both its apply and the lookup, in either order.
  local landed, settled, against = false, not asking, point.against
  apply(point.base, function(err)
    if err then
      return fail(err)
    end
    landed = true
    if settled then
      announce(against)
    end
  end)
  if not asking then
    return warn_skipped(point)
  end
  waiting = function(answer)
    if answer.against ~= answer.default_branch and answer.base ~= want then
      return apply(answer.base, function(err)
        if err then
          fail(err)
        else
          announce(answer.against)
        end
      end)
    end
    warn_skipped(answer)
    against = answer.against
    settled = true
    if landed then
      announce(against)
    end
  end
end

---Whether the mode turns itself on for `branch` at `root`.
---@param root string
---@param branch string
---@return boolean
local function wanted(root, branch)
  return not dismissed[root .. "\n" .. branch] and branch ~= Git.default_base(root)
end

---Follow a change of repository or branch. Re-resolves the base even when the
---mode is already on, since the fork point belongs to the branch left behind.
---@param root string
---@param branch string
local function sync(root, branch)
  if root == toplevel and branch == applied then
    return
  end
  toplevel, applied = root, branch
  if wanted(root, branch) then
    enable(root, branch, false)
  elseif is_on() then
    apply(nil)
  end
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
  local detached = status and status.root and Git.head(status.root) == "HEAD"
  if status and status.root and status.head and status.head ~= "" and not detached then
    return status.root, status.head
  end
end

---Switch the mode off for the current buffer's branch for the rest of the session, or back on.
---A buffer gitsigns doesn't track toggles the mode's own repository and branch.
---Needs `activate()`: without it the mode never follows a branch change.
function M.toggle()
  local root, branch = tracked(vim.api.nvim_get_current_buf())
  if not root then
    root, branch = toplevel, applied
  end
  if not root or not branch then
    return vim.notify("PR Review Mode: no buffer gitsigns tracks", vim.log.levels.WARN)
  end
  local on = is_on()
  if root ~= toplevel or branch ~= applied then
    toplevel, applied = root, branch
    on = wanted(root, branch)
  end
  if on then
    -- Also drops the old repository's `want` and `waiting`, which would claim this one's buffers.
    apply(nil)
    dismissed[root .. "\n" .. branch] = true
    vim.notify("PR Review Mode: off")
  else
    dismissed[root .. "\n" .. branch] = nil
    enable(root, branch, true)
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

---Register the `User GitSignsUpdate` autocmd that turns the mode on for every branch but the
---default and keeps buffers on its base. Safe to call more than once.
function M.activate()
  fork_point.subscribe(on_answer)
  -- gitsigns republishes a buffer's branch on every sign refresh, including after
  -- a checkout made outside Neovim, so this doubles as a repository- and
  -- branch-change hook, and each event also moves buffers that missed the base.
  -- Its cwd-wide sibling event carries no buffer and is skipped: that watcher
  -- never starts in a worktree, where `.git` is a file rather than a directory.
  vim.api.nvim_create_autocmd("User", {
    group = vim.api.nvim_create_augroup("changeset.review", { clear = true }),
    pattern = "GitSignsUpdate",
    desc = "changeset: keep buffers on PR Review Mode's base as the repository or branch changes",
    callback = function(args)
      local root, branch
      if args.data then
        root, branch = tracked(args.data.buffer)
      end
      if root and branch then
        sync(root, branch)
      end
      reconcile()
    end,
  })
end

return M
