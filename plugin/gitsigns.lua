-- github.com/lewis6991/gitsigns.nvim
-- Git change indicators in the sign column
vim.pack.add({ "https://github.com/lewis6991/gitsigns.nvim" })
require("gitsigns").setup()

-- PR Review Mode points gitsigns' base at this branch's fork point from the
-- default branch, so the gutter marks everything the branch changed rather than
-- just uncommitted work. It turns itself on off the default branch; `:PRReview`
-- turns it off, and each branch remembers that choice for the session.

---@type table<string, true> Branches the mode was switched off on.
local dismissed = {}

---@type string? Branch the global base was last resolved for.
local applied

---@type string? Base every buffer should diff against; nil is the index.
local want

---@type string? Toplevel of the repository the mode acts on.
local toplevel

---@type table<string, true> Bases `apply` has set.
local ours = {}

---@type table<integer, string|false> Buffers with a move in flight, by target; false is the index.
local moving = {}

---Whether the mode is on (its intent; gitsigns may still be catching up).
---@return boolean
local function is_on()
  return want ~= nil
end

-- Reaches into gitsigns internals: its buffer cache, config.base, git_obj.revision
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

---Point every owned buffer, and every buffer attached from now on, at `base`.
---@param base string?
---@param done fun(err: string?)? Called once every move has landed, with the first error.
local function apply(base, done)
  want = base
  toplevel = require("helpers.git").lines({ "git", "rev-parse", "--show-toplevel" })[1]
  if base then
    ours[base] = true
  end
  require("gitsigns.config").config.base = base
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

---Diff against the fork point from the default branch.
---@param report boolean Announce success; failures announce regardless.
local function enable(report)
  local base, branch = require("helpers.git").merge_base()
  if not base then
    vim.notify("PR Review Mode: no merge base with the default branch", vim.log.levels.WARN)
    return
  end
  apply(base, function(err)
    if err then
      vim.notify("PR Review Mode: " .. err, vim.log.levels.ERROR)
    elseif report then
      vim.notify("PR Review Mode: on (vs " .. branch .. ")")
    end
  end)
end

---Follow a branch change. Re-resolves the base even when the mode is already
---on, since the fork point belongs to the branch that was left behind.
---@param branch string
local function sync(branch)
  if branch == applied then
    return
  end
  applied = branch
  if dismissed[branch] or branch == require("helpers.git").default_base() then
    if is_on() then
      apply(nil)
    end
  else
    enable(false)
  end
end

vim.api.nvim_create_user_command("PRReview", function()
  local branch = vim.b.gitsigns_head or ""
  if is_on() then
    apply(nil)
    dismissed[branch] = true
    vim.notify("PR Review Mode: off")
  else
    dismissed[branch] = nil
    enable(true)
  end
end, { desc = "Toggle PR Review Mode for this branch" })

-- gitsigns republishes a buffer's branch on every sign refresh, including after
-- a checkout made outside Neovim, so this doubles as a branch-change hook, and
-- each event also moves buffers that missed the base. Its cwd-wide sibling
-- event carries no buffer and is skipped: that watcher never starts in a
-- worktree, where `.git` is a file rather than a directory.
vim.api.nvim_create_autocmd("User", {
  pattern = "GitSignsUpdate",
  callback = function(args)
    local branch = args.data and vim.b[args.data.buffer].gitsigns_head
    if branch and branch ~= "" then
      sync(branch)
    end
    reconcile()
  end,
})
