-- Minimal init for plenary test harness

-- Neovim's default rtp and packpath include the user config even under -u; a
-- spec must not resolve a module from it.
vim.opt.rtp:remove(vim.fn.stdpath("config"))
vim.opt.rtp:remove(vim.fn.stdpath("config") .. "/after")
vim.opt.packpath:remove(vim.fn.stdpath("config"))
vim.opt.packpath:remove(vim.fn.stdpath("config") .. "/after")
-- Concurrent or killed test nvims corrupt the editor's shared ShaDa file (E576, E136).
vim.o.shadafile = "NONE"
-- A `[No Name]` swap is named after the cwd, so parallel specs exhaust its
-- rotation and one dies with E303 on `enew`.
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
-- The repo root is two levels up from this file, wherever nvim was started.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
-- `rtp` reaches `lua/` only, so fixture modules under `tests/support/` need their own path.
package.path = root .. "/tests/?.lua;" .. package.path
-- Startup put the editor's data dir on rtp, and with it the editor's treesitter
-- parsers; a spec must find only the ones `mise run parsers` installed.
vim.opt.rtp:remove(vim.fn.stdpath("data") .. "/site")
vim.opt.rtp:remove(vim.fn.stdpath("data") .. "/site/after")
vim.opt.packpath:remove(vim.fn.stdpath("data") .. "/site")
vim.opt.packpath:remove(vim.fn.stdpath("data") .. "/site/after")
local parsers = require("support.parsers")
vim.env.XDG_DATA_HOME = parsers.data_home
vim.opt.rtp:prepend(parsers.site)
vim.opt.rtp:prepend(require("support.deps").path("plenary.nvim"))
if vim.env.LUACOV then
  require("support.coverage").start()
end
vim.cmd("runtime plugin/plenary.vim")
