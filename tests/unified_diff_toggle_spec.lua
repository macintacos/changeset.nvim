vim.opt.rtp:prepend(require("support.deps").path("gitsigns.nvim"))
require("gitsigns").setup()
require("support.gh")

local changeset = require("changeset")
local config = require("changeset.config")
local window = require("changeset.window")
local Fixture = require("support.git")
local Notify = require("support.notify")
local present = require("support.present")

-- One session, told case by case, each starting where the one before left it: the first has no tree to work with.
describe(":Changeset diff and :Changeset diff split", function()
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

  ---Whether `win` comes to show the side-by-side diff: it and one other window in diff mode.
  ---@param win integer
  ---@return boolean
  local function paired(win)
    return (
      vim.wait(5000, function()
        return vim.wo[win].diff
          and #vim.tbl_filter(function(w)
              return vim.wo[w].diff
            end, vim.api.nvim_tabpage_list_wins(0))
            == 2
      end, 20)
    )
  end

  it("warns, staying off, when there is no tree and no merge base to build one on", function()
    vim.fn.chdir(nowhere)

    changeset.diff()

    vim.fn.chdir(dir)
    assert.equal(1, #notes)
    assert.equal(vim.log.levels.WARN, present(notes[1]).level)
    assert.truthy(present(notes[1]).msg:find("no merge base", 1, true), present(notes[1]).msg)
  end)

  it("builds the current buffer's tree when none is built, then turns on side by side, saying so", function()
    vim.cmd.edit("mod.lua")

    changeset.diff_split()

    assert.same({ "Changeset: side-by-side diff on" }, Notify.messages({ notes[2] }))
    assert.is_true(paired(vim.api.nvim_get_current_win()))
  end)

  it("switches back to unified, saying so", function()
    changeset.diff_split()

    assert.same({ "Changeset: unified diff on" }, Notify.messages({ notes[3] }))
    assert.is_true(vim.wait(5000, function()
      return view(vim.api.nvim_get_current_win()) ~= nil
    end, 20))
  end)

  it("turns off everywhere with the sidebar closed, naming the view", function()
    changeset.diff()

    assert.same({ "Changeset: unified diff off" }, Notify.messages({ notes[4] }))
    assert.is_nil(view(vim.api.nvim_get_current_win()))
  end)

  it("names the side-by-side view as it turns off", function()
    changeset.diff_split()

    changeset.diff()

    assert.same({ "Changeset: side-by-side diff off" }, Notify.messages({ notes[6] }))
  end)

  it("reaches no further than the entered files after the sidebar closes under keep = entered", function()
    config.setup({ unified_diff = { keep = "entered" } })
    local file_win = vim.api.nvim_get_current_win()
    changeset.open()
    assert.is_true(vim.wait(10000, function()
      return window.buf() ~= nil
    end, 25))
    vim.api.nvim_set_current_win(file_win)
    vim.cmd.edit("mod.lua")
    changeset.close()
    vim.cmd.edit("other.lua")

    changeset.diff_split()

    assert.is_false(vim.wait(500, function()
      return vim.wo[file_win].diff or view(file_win) ~= nil
    end, 20))
  end)

  restore()
  config.setup({})
  vim.cmd("silent! %bwipeout!")
  vim.fn.chdir(previous)
  vim.fn.delete(dir, "rf")
  vim.fn.delete(nowhere, "rf")
end)
