-- Minimal init for plenary test harness

-- Neovim's default rtp includes the user config even under -u.
vim.opt.rtp:remove(vim.fn.stdpath("config"))
vim.opt.rtp:remove(vim.fn.stdpath("config") .. "/after")
-- Headless test nvims must never touch the shared ShaDa file. Without this,
-- every spec's child nvim reads and writes ~/.local/state/nvim/*/shada/main.shada
-- alongside the interactive editor; concurrent or signal-killed children
-- interleave their writes and corrupt it (E576, then E136 on every later write).
vim.o.shadafile = "NONE"
-- Nor may they write swap files. A `[No Name]` buffer names its swap after the
-- current directory, so every child plenary runs in parallel wants the same one;
-- the rotation runs out after a dozen or so and the loser dies with E303 in
-- whichever spec happened to call `enew`.
vim.o.swapfile = false
-- Keep stdpath("state") and stdpath("cache") consumers, such as changeset's
-- preferences and tree cache, isolated per test process.
vim.env.XDG_STATE_HOME = vim.fn.tempname()
vim.fn.mkdir(vim.env.XDG_STATE_HOME, "p")
vim.env.XDG_CACHE_HOME = vim.fn.tempname()
vim.fn.mkdir(vim.env.XDG_CACHE_HOME, "p")
-- Git hooks export GIT_DIR and friends, and those override cwd-based repo
-- discovery — under `pre-push` a spec's fixture repo would otherwise operate on
-- the repo being pushed. No restore: each spec runs in its own child nvim.
for name in pairs(vim.fn.environ()) do
  if name:match("^GIT_") then
    vim.env[name] = nil
  end
end
-- Set after the scrub, which would otherwise delete them. User and system git
-- config (`diff.noprefix`, say) reshapes the output the specs parse.
vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
vim.env.GIT_CONFIG_SYSTEM = "/dev/null"
-- Run against the repo tree this init lives in (the repo root is two levels up
-- from tests/minimal_init.lua), so the suite also works from a git worktree.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
-- `rtp` reaches `lua/` only, so fixture modules under `tests/support/` need their own path.
package.path = root .. "/tests/?.lua;" .. package.path
vim.opt.rtp:prepend(require("support.deps").path("plenary.nvim"))
if vim.env.LUACOV then
  require("support.coverage").start()
end
vim.cmd("runtime plugin/plenary.vim")
