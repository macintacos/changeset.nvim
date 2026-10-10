vim.opt.rtp:prepend(require("support.deps").path("gitsigns.nvim"))
require("gitsigns").setup()
require("support.gh")

local changeset = require("changeset")
local Fixture = require("support.git")
local Notify = require("support.notify")
local present = require("support.present")

-- One session, told case by case, each starting where the one before left it: the first has no tree to work with.
describe(":Changeset diff", function()
  local dir, previous = Fixture.enter_tempdir()
  Fixture.feature_two_files(dir)
  local nowhere = vim.fn.tempname()
  vim.fn.mkdir(nowhere, "p")
  local notes, restore = Notify.capture()

  ---@param win integer
  ---@return Gitsigns.UnifiedView?
  local function view(win)
    return require("gitsigns.unified").get_view(win)
  end

  it("warns, staying off, when there is no tree and no merge base to build one on", function()
    vim.fn.chdir(nowhere)

    changeset.diff()

    vim.fn.chdir(dir)
    assert.equal(1, #notes)
    assert.equal(vim.log.levels.WARN, present(notes[1]).level)
    assert.truthy(present(notes[1]).msg:find("no merge base", 1, true), present(notes[1]).msg)
  end)

  it("builds the current buffer's tree when none is built, then turns on, saying so", function()
    vim.cmd.edit("mod.lua")

    changeset.diff()

    assert.same({ "Changeset: unified diff on" }, Notify.messages({ notes[2] }))
    assert.is_true(vim.wait(5000, function()
      return view(vim.api.nvim_get_current_win()) ~= nil
    end, 20))
  end)

  it("turns off everywhere with the sidebar closed, saying so", function()
    changeset.diff()

    assert.same({ "Changeset: unified diff off" }, Notify.messages({ notes[3] }))
    assert.is_nil(view(vim.api.nvim_get_current_win()))
  end)

  restore()
  vim.cmd("silent! %bwipeout!")
  vim.fn.chdir(previous)
  vim.fn.delete(dir, "rf")
  vim.fn.delete(nowhere, "rf")
end)
