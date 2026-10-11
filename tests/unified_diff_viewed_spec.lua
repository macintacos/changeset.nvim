vim.opt.rtp:prepend(require("support.deps").path("gitsigns.nvim"))
require("gitsigns").setup()
require("support.gh")

local build = require("changeset.build")
local changeset = require("changeset")
local Fixture = require("support.git")
local Sidebar = require("support.sidebar")
local present = require("support.present")

-- One session, told case by case, each starting where the one before left it.
describe("the unified diff of a file marked viewed", function()
  local dir, previous = Fixture.enter_tempdir()
  Fixture.feature_two_files(dir)
  local quiet = vim.notify
  vim.notify = function() end
  vim.cmd.edit("mod.lua")
  local file_win = vim.api.nvim_get_current_win()
  local mod = vim.api.nvim_get_current_buf()
  changeset.open()
  Sidebar.settle()

  ---@param win integer
  ---@return boolean
  local function viewing(win)
    return require("gitsigns.unified").get_view(win) ~= nil
  end

  ---Whether `win` comes to show a unified diff, or with `want` false, comes to show none.
  ---@param want boolean
  ---@return boolean
  local function becomes(want)
    return (vim.wait(5000, function()
      return viewing(file_win) == want
    end, 20))
  end

  ---Whether it stays without a view for half a second.
  ---@return boolean
  local function stays_bare()
    return not vim.wait(500, function()
      return viewing(file_win)
    end, 20)
  end

  ---The marks changeset lays over gitsigns' signs in the file's window.
  ---@return integer
  local function covers()
    vim.cmd.redraw()
    local ns = vim.api.nvim_create_namespace("changeset.unified_diff." .. file_win)
    return #vim.api.nvim_buf_get_extmarks(mod, ns, 0, -1, {})
  end

  local function toggle()
    Sidebar.cursor_to("mod.lua")
    vim.api.nvim_feedkeys("x", "xt", false)
    vim.api.nvim_set_current_win(file_win)
  end

  ---The digest of mod.lua's diff the tree holds.
  ---@return string?
  local function digest()
    local file = vim.iter(present(build.current()).files):find(function(f)
      return f.path == "mod.lua"
    end)
    return file and file.digest
  end

  ---Write `lines` to mod.lua and wait for the tree to read its diff again.
  ---@param lines string[]
  local function rewrite(lines)
    local was = digest()
    vim.api.nvim_buf_set_lines(mod, 0, -1, false, lines)
    vim.api.nvim_buf_call(mod, function()
      vim.cmd("silent write")
    end)
    build.refresh()
    assert.is_true(vim.wait(5000, function()
      return digest() ~= was
    end, 20))
  end

  it("closes the file's view and its cover once marked", function()
    assert.is_true(becomes(true))

    toggle()

    assert.is_true(becomes(false))
    assert.equal(0, covers())
  end)

  it("opens no view on the file as its window is entered", function()
    vim.cmd.wincmd("p")
    vim.api.nvim_set_current_win(file_win)

    assert.is_true(stays_bare())
  end)

  it("keeps the file without a view as the diff turns off and on", function()
    changeset.diff()
    changeset.diff()

    assert.is_true(stays_bare())
  end)

  it("reopens the view once the file's diff changes", function()
    rewrite({ "local M = {}", "", "function M.one()", "  return 3", "end", "", "return M" })

    assert.is_true(becomes(true))
  end)

  it("closes it again once the file is back to the diff it was viewed at", function()
    rewrite({ "local M = {}", "", "function M.one()", "  return 2", "end", "", "return M" })

    assert.is_true(becomes(false))
  end)

  it("reopens the view once unmarked", function()
    toggle()

    assert.is_true(becomes(true))
  end)

  vim.notify = quiet
  changeset.close()
  vim.cmd("silent! %bwipeout!")
  vim.fn.chdir(previous)
  vim.fn.delete(dir, "rf")
end)
