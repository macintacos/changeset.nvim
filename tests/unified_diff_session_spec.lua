vim.opt.rtp:prepend(require("support.deps").path("gitsigns.nvim"))
require("gitsigns").setup()
require("support.gh")

local build = require("changeset.build")
local changeset = require("changeset")
local config = require("changeset.config")
local window = require("changeset.window")
local Fixture = require("support.git")
local Sidebar = require("support.sidebar")

-- One session, told case by case: each case starts where the one before left it. plenary runs each case as it is
-- declared, so the repository is made before the first and removed after the last.
describe("the unified diff over a session", function()
  local dir, previous = Fixture.enter_tempdir()
  Fixture.feature_two_files(dir)
  vim.fn.writefile({ "return 4" }, "untracked.lua")
  vim.fn.writefile({ "return 5" }, "later.lua")
  -- As the gutter's base has it, so each view draws what the branch changed.
  require("gitsigns").change_base("trunk", true)
  local quiet = vim.notify
  vim.notify = function() end

  ---@param win integer
  ---@return Gitsigns.UnifiedView?
  local function view(win)
    return require("gitsigns.unified").get_view(win)
  end

  ---Whether `win` shows a unified diff, once it does.
  ---@param win integer
  ---@return boolean
  local function shows(win)
    return vim.wait(5000, function()
      return view(win) ~= nil
    end, 20)
  end

  ---Whether `win` still shows no unified diff half a second on.
  ---@param win integer
  ---@return boolean
  local function bare(win)
    return not vim.wait(500, function()
      return view(win) ~= nil
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

  ---The sign column beside the first line of `win`, once drawn.
  ---@param win integer
  ---@return string
  local function sign(win)
    vim.cmd.redraw()
    return vim.fn.screenstring(vim.fn.screenpos(win, 1, 1).row, vim.fn.getwininfo(win)[1].wincol)
  end

  it("opens nothing before the sidebar opens, though the tree is built", function()
    vim.cmd.edit("mod.lua")

    changeset.refresh()

    assert.is_true(vim.wait(5000, function()
      return assert(build.current()).collected
    end, 20))
    assert.is_true(bare(file_window("mod.lua")))
  end)

  it("opens it in the windows already open once the sidebar opens, an untracked file's among them", function()
    vim.cmd.split("untracked.lua")

    changeset.open()

    assert.is_true(shows(file_window("mod.lua")))
    assert.is_true(shows(file_window("untracked.lua")))
  end)

  it("opens none in a file the tree doesn't list", function()
    vim.cmd.split("plain.lua")

    assert.is_true(bare(file_window("plain.lua")))
    vim.cmd.close()
  end)

  it("closes every view at once as the sidebar closes, each cursor staying on its line", function()
    local mod = file_window("mod.lua")
    vim.api.nvim_win_set_cursor(mod, { 4, 0 })

    changeset.close()

    assert.is_nil(view(mod))
    assert.is_nil(view(file_window("untracked.lua")))
    assert.same({ 4, 0 }, vim.api.nvim_win_get_cursor(mod))
    assert.is_false(require("gitsigns.config").config.attach_to_untracked)
  end)

  it("closes the view of the file <S-CR> opens as it closes the sidebar", function()
    changeset.open()
    Sidebar.settle()
    Sidebar.cursor_to("other.lua")

    vim.cmd.normal(vim.keycode("<S-CR>"))

    assert.is_nil(window.win())
    assert.equal(file_window("other.lua"), vim.api.nvim_get_current_win())
    assert.is_true(bare(file_window("other.lua")))
  end)

  it(
    "keeps every view as the sidebar closes under keep = all, and opens one in a file of the tree opened after",
    function()
      config.setup({ unified_diff = { keep = "all" } })
      changeset.open()
      assert.is_true(shows(file_window("other.lua")))

      changeset.close()
      vim.cmd.edit("later.lua")

      assert.is_true(shows(file_window("later.lua")))
      assert.is_true(shows(file_window("mod.lua")))
    end
  )

  it("never turns back on as the sidebar closes, once turned off while it was open", function()
    changeset.open()
    changeset.diff()
    assert.is_nil(view(file_window("mod.lua")))

    changeset.close()
    vim.cmd.edit("other.lua")

    assert.is_true(bare(file_window("other.lua")))
    assert.is_true(bare(file_window("mod.lua")))
  end)

  it("closes a view by hand in that file alone, giving its signs back, and keeps it closed", function()
    changeset.diff()
    local other, mod = file_window("other.lua"), file_window("mod.lua")
    assert.is_true(shows(other))
    assert.equal(" ", sign(other))
    vim.api.nvim_set_current_win(other)

    vim.cmd("Gitsigns diffthis unified=true")
    vim.api.nvim_set_current_win(mod)
    vim.api.nvim_set_current_win(other)
    vim.cmd.split()

    assert.is_true(bare(other))
    assert.is_true(bare(vim.api.nvim_get_current_win()))
    assert.equal("┃", sign(other))
    assert.is_true(shows(mod))
    vim.cmd.close()
  end)

  it("opens the view closed by hand again once the sidebar next opens", function()
    changeset.open()

    assert.is_true(shows(file_window("other.lua")))
  end)

  changeset.close()
  config.setup()
  vim.notify = quiet
  vim.cmd("silent! %bwipeout!")
  vim.fn.chdir(previous)
  vim.fn.delete(dir, "rf")
end)
