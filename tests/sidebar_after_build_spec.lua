local Fixture = require("support.git")
local Symbols = require("support.symbols")
local present = require("support.present")
require("support.gh")

describe("the sidebar loaded after the tree's diff was read", function()
  local build = require("changeset.build")
  local tmp ---@type string
  local previous_dir ---@type string
  local symbols ---@type support.symbols.Source

  before_each(function()
    tmp, previous_dir = Fixture.enter_tempdir()
    symbols = Symbols.install()
  end)

  after_each(function()
    symbols.restore()
    require("changeset").close()
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
  end)

  it("hands the picker the rows of that diff", function()
    Fixture.feature_one_file(tmp)
    build.build()
    assert.is_true(vim.wait(10000, function()
      return present(build.current()).collected
    end, 10))

    local tree = present(require("changeset").rows())

    assert.same(
      { "mod.lua" },
      vim.tbl_map(function(row)
        return row.path
      end, tree.rows)
    )
  end)
end)
