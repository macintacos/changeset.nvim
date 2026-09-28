---The treesitter parsers the specs parse with, installed by nvim-treesitter under
---`.tests/data`: the data dir `tests/minimal_init.lua` gives the suite, so no spec
---reads the editor's own parsers. `nvim -l tests/support/parsers.lua` installs them.
local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h:h")

local M = {}

---@type string
M.data_home = root .. "/.tests/data"
---Where `install()` puts the parsers, and the `site` the suite puts on `rtp`.
---@type string
M.site = M.data_home .. "/nvim/site"

local langs = { "rust", "typescript", "tsx" }
local INSTALL_TIMEOUT_MS = 5 * 60 * 1000

---Install or rebuild whichever parser is missing or stale, raising if any still is afterwards.
function M.install()
  -- nvim-treesitter wipes and re-downloads <cache>/tree-sitter-<lang>; keep that
  -- scratch work out of the editor's cache.
  vim.env.XDG_CACHE_HOME = vim.fn.tempname()
  vim.opt.rtp:prepend(require("support.deps").path("nvim-treesitter"))
  local ts = require("nvim-treesitter")
  ts.setup({ install_dir = M.site })
  ts.install(langs):wait(INSTALL_TIMEOUT_MS)
  ts.update(langs):wait(INSTALL_TIMEOUT_MS)
  local missing = vim.tbl_filter(function(lang)
    return not vim.uv.fs_stat(M.site .. "/parser/" .. lang .. ".so")
  end, langs)
  if #missing > 0 then
    error("parsers not installed: " .. table.concat(missing, ", "), 0)
  end
end

if arg and arg[0] and vim.fn.fnamemodify(arg[0], ":p") == vim.fn.fnamemodify(this, ":p") then
  package.path = root .. "/tests/?.lua;" .. package.path
  M.install()
end

return M
