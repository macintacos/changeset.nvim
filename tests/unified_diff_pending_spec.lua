vim.opt.rtp:prepend(require("support.deps").path("gitsigns.nvim"))
require("gitsigns").setup()
require("support.gh")

local build = require("changeset.build")
local Fixture = require("support.git")
local Notify = require("support.notify")

describe(":Changeset diff before the first build lands", function()
  local dir, previous ---@type string, string
  local notes, restore ---@type support.notify.Note[], fun()

  before_each(function()
    dir, previous = Fixture.enter_tempdir()
    Fixture.feature_two_files(dir)
    vim.cmd.edit("mod.lua")
    notes, restore = Notify.capture()
  end)

  after_each(function()
    restore()
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous)
    vim.fn.delete(dir, "rf")
  end)

  it("twice leaves the diff off", function()
    vim.cmd("runtime plugin/changeset.lua")

    vim.cmd("Changeset diff")
    vim.cmd("Changeset diff")
    assert.is_true(vim.wait(10000, function()
      return build.kept() ~= nil
    end, 10))
    vim.wait(100)

    assert.is_false(require("changeset.unified_diff").on())
    assert.same({}, Notify.messages(notes))
  end)
end)
