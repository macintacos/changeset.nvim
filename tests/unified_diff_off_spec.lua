vim.opt.rtp:prepend(require("support.deps").path("gitsigns.nvim"))
require("gitsigns").setup()

local changeset = require("changeset")
local window = require("changeset.window")
local Fixture = require("support.git")

-- One session, told case by case: each case starts where the one before left it. plenary runs each case as it is
-- declared, so the repository is made before the first and removed after the last.
describe("the unified diff over a session", function()
  local dir, previous = Fixture.enter_tempdir()
  Fixture.feature_two_files(dir)
  vim.fn.writefile({ "return 3" }, "plain.lua")

  ---@param win integer
  ---@return boolean
  local function shows(win)
    return vim.wait(1000, function()
      return require("gitsigns.unified").get_view(win) ~= nil
    end, 20)
  end

  ---The window showing `name`, once gitsigns has its base text.
  ---@param name string
  ---@return integer
  local function file_window(name)
    local buf = vim.fn.bufnr(name)
    assert.is_true(vim.wait(5000, function()
      local bcache = require("gitsigns.cache").cache[buf]
      return bcache ~= nil and bcache.compare_text ~= nil
    end, 20))
    return vim.fn.bufwinid(buf)
  end

  it("opens nothing before the sidebar opens", function()
    vim.cmd.edit("mod.lua")

    assert.is_false(shows(file_window("mod.lua")))
  end)

  it("opens it in the windows already open once the sidebar opens", function()
    changeset.open()

    assert.is_true(shows(file_window("mod.lua")))
  end)

  it("stays on after the sidebar closes", function()
    changeset.close()
    vim.api.nvim_set_current_win(file_window("mod.lua"))

    vim.cmd.edit("other.lua")

    assert.is_true(shows(file_window("other.lua")))
  end)

  it("turns off everywhere once closed in one window", function()
    vim.api.nvim_set_current_win(file_window("other.lua"))
    vim.cmd("Gitsigns diffthis unified=true")
    assert.is_false(shows(file_window("other.lua")))

    vim.cmd.edit("plain.lua")

    assert.is_false(shows(file_window("plain.lua")))
  end)

  it("stays off when the sidebar opens again", function()
    vim.cmd.edit("mod.lua")
    changeset.open()
    assert.truthy(window.win())

    assert.is_false(shows(file_window("mod.lua")))
  end)

  changeset.close()
  vim.cmd("silent! %bwipeout!")
  vim.fn.chdir(previous)
  vim.fn.delete(dir, "rf")
end)
