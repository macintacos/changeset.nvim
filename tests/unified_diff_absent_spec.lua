require("support.gh")
local changeset = require("changeset")
local Fixture = require("support.git")
local Notify = require("support.notify")

describe(":Changeset diff without gitsigns", function()
  assert.is_falsy(pcall(require, "gitsigns"), "gitsigns must not be installed")

  it("warns that the diff needs gitsigns, in either view, staying off", function()
    local dir, previous = Fixture.enter_tempdir()
    Fixture.feature_one_file(dir)
    vim.cmd.edit("mod.lua")
    local notes, restore = Notify.capture()

    changeset.diff()
    changeset.diff_split()

    restore()
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous)
    vim.fn.delete(dir, "rf")
    assert.same({
      { msg = "Changeset: the diff needs gitsigns", level = vim.log.levels.WARN },
      { msg = "Changeset: the diff needs gitsigns", level = vim.log.levels.WARN },
    }, notes)
  end)
end)
