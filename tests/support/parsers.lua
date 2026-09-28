---The treesitter parsers the specs parse with, installed by nvim-treesitter under
---`.tests/data`: the data dir `tests/minimal_init.lua` gives the suite, so no spec
---reads the editor's own parsers. `nvim -l tests/support/parsers.lua` installs them.
local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h:h")

local M = {}

---@type string
M.data_home = root .. "/.tests/data"

local langs = { "rust", "typescript", "tsx" }

---Install whichever parser is missing, raising if any still is afterwards.
function M.install()
  vim.env.XDG_DATA_HOME = M.data_home
  -- nvim-treesitter downloads into, and first deletes, <cache>/tree-sitter-<lang>.
  vim.env.XDG_CACHE_HOME = vim.fn.tempname()
  vim.fn.mkdir(vim.env.XDG_CACHE_HOME, "p")
  local site = vim.fn.stdpath("data") .. "/site"
  vim.opt.rtp:prepend(require("support.deps").path("nvim-treesitter"))
  local ts = require("nvim-treesitter")
  ts.setup({ install_dir = site })
  ts.install(langs):wait(300000)
  local missing = vim.tbl_filter(function(lang)
    return not vim.uv.fs_stat(site .. "/parser/" .. lang .. ".so")
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
