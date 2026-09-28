---luacov's settings for `mise run coverage`, shared by the spec processes that
---record line hits (through minimal_init) and `nvim -l tests/support/coverage.lua`,
---which writes the report.
local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h:h")

local M = {}

M.config = {
  statsfile = root .. "/.tests/luacov/stats.out",
  reportfile = root .. "/.tests/luacov/report.out",
  include = { "^" .. vim.pesc(root) .. "/lua/" },
  -- Modules no spec loads still get a row, at 0%.
  includeuntestedfiles = { root .. "/lua" },
}

local function add_luacov_to_path()
  package.path = require("support.deps").path("luacov") .. "/src/?.lua;" .. package.path
end

---Record line hits for the rest of this process.
function M.start()
  add_luacov_to_path()
  local runner = require("luacov.runner")
  runner.init(M.config)
  -- Flushes this process's hits to the stats file as the spec process exits.
  -- plenary exits with :cq, which fires VimLeavePre but none of the exit paths
  -- luacov hooks itself (os.exit, or finalizers at Lua state close).
  vim.api.nvim_create_autocmd("VimLeavePre", { callback = runner.shutdown })
end

---Write the report from the stats the spec processes recorded.
function M.report()
  add_luacov_to_path()
  -- The reporter needs lfs only to find the untested files.
  package.preload.lfs = function()
    return {
      dir = vim.fs.dir,
      attributes = function(path)
        local stat = vim.uv.fs_stat(path)
        return stat and { mode = stat.type }
      end,
    }
  end
  require("luacov.runner").run_report(M.config)
end

if arg and arg[0] and vim.fn.fnamemodify(arg[0], ":p") == vim.fn.fnamemodify(this, ":p") then
  package.path = root .. "/tests/?.lua;" .. package.path
  M.report()
end

return M
