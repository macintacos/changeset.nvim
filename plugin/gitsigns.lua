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

---@return boolean
local function is_on()
  return require("gitsigns.config").config.base ~= nil
end

---Diff against the fork point from the default branch.
---@param report boolean Announce success; failures announce regardless.
local function enable(report)
  local base, branch = require("helpers.git").merge_base()
  if not base then
    vim.notify("PR Review Mode: no merge base with the default branch", vim.log.levels.WARN)
    return
  end
  require("gitsigns").change_base(base, true, function(err)
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
      require("gitsigns").reset_base(true)
    end
  else
    enable(false)
  end
end

vim.api.nvim_create_user_command("PRReview", function()
  local branch = vim.b.gitsigns_head or ""
  if is_on() then
    require("gitsigns").reset_base(true)
    dismissed[branch] = true
    vim.notify("PR Review Mode: off")
  else
    dismissed[branch] = nil
    enable(true)
  end
end, { desc = "Toggle PR Review Mode for this branch" })

-- gitsigns republishes a buffer's branch on every sign refresh, including after
-- a checkout made outside Neovim, so this doubles as a branch-change hook. Its
-- cwd-wide sibling event carries no buffer and is skipped: that watcher never
-- starts in a worktree, where `.git` is a file rather than a directory.
vim.api.nvim_create_autocmd("User", {
  pattern = "GitSignsUpdate",
  callback = function(args)
    local branch = args.data and vim.b[args.data.buffer].gitsigns_head
    if branch and branch ~= "" then
      sync(branch)
    end
  end,
})
