vim.opt.rtp:prepend(require("support.deps").path("gitsigns.nvim"))
require("gitsigns").setup()
require("support.gh")

local changeset = require("changeset")
local config = require("changeset.config")
local pick = require("changeset.pick")
local window = require("changeset.window")
local Fixture = require("support.git")
local Sidebar = require("support.sidebar")

-- A file stays entered for the rest of the session, so each case enters, or only looks at, a file of its own.
local FILES = {
  "browse",
  "chosen",
  "close",
  "edit",
  "enter",
  "found",
  "hsplit",
  "other",
  "preview",
  "quiet",
  "step",
  "tab",
  "vsplit",
  "walk",
}

describe("the unified diff once the sidebar closes under keep = entered", function()
  local dir, previous = Fixture.enter_tempdir()
  local base, change = { ["plain.lua"] = { "return 0" } }, {}
  for _, name in ipairs(FILES) do
    base[name .. ".lua"] = { "return 1" }
    change[name .. ".lua"] = { "return 2" }
  end
  Fixture.feature(base, change, dir)
  config.setup({ unified_diff = { keep = "entered" } })
  vim.cmd.edit("plain.lua")
  local file_win = vim.api.nvim_get_current_win()
  local real_select, quiet = vim.ui.select, vim.notify
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

  ---The window showing `name`.lua, in any tabpage.
  ---@param name string
  ---@return integer
  local function window_of(name)
    return assert(vim.fn.win_findbuf(vim.fn.bufnr(name .. ".lua"))[1], name .. ".lua is in no window")
  end

  ---Close the sidebar, then whether the window showing `name`.lua keeps its unified diff.
  ---@param name string
  ---@return boolean
  local function keeps(name)
    changeset.close()
    return shows(window_of(name))
  end

  ---Close the sidebar, open `name`.lua where the sidebar's files opened, and whether it shows no unified diff once
  ---gitsigns has its base, half a second on.
  ---@param name string
  ---@return boolean
  local function left_bare(name)
    changeset.close()
    vim.api.nvim_set_current_win(file_win)
    vim.cmd.edit(name .. ".lua")
    local buf = vim.api.nvim_get_current_buf()
    assert.is_true(vim.wait(5000, function()
      local bcache = require("gitsigns.cache").cache[buf]
      return bcache ~= nil and bcache.compare_text ~= nil
    end, 20))
    return not vim.wait(500, function()
      return view(file_win) ~= nil
    end, 20)
  end

  ---The sidebar's line holding `text`.
  ---@param text string
  ---@return integer
  local function line_of(text)
    for lnum, line in ipairs(Sidebar.lines()) do
      if line:find(text, 1, true) then
        return lnum
      end
    end
    error("no sidebar line holds " .. text)
  end

  ---Pick `name`.lua from the picker, as `vim.ui.select` answers.
  ---@param name string
  local function pick_file(name)
    local choose
    vim.ui.select = function(items, _, on_choice)
      choose = function()
        on_choice(vim.iter(items):find(function(item)
          return vim.endswith(item.path, "/" .. name .. ".lua")
        end))
      end
    end
    pick.pick()
    vim.ui.select = real_select
    assert(choose, "the picker offered nothing")()
  end

  before_each(function()
    vim.api.nvim_set_current_win(file_win)
    vim.cmd.buffer("plain.lua")
    changeset.open()
    Sidebar.settle()
  end)

  after_each(function()
    changeset.close()
    vim.api.nvim_set_current_win(file_win)
    vim.cmd("silent! tabonly")
    vim.cmd("silent! only")
  end)

  for key, name in pairs({
    ["<CR>"] = "enter",
    ["<S-CR>"] = "close",
    ["<C-v>"] = "vsplit",
    ["<C-x>"] = "hsplit",
    ["<C-t>"] = "tab",
  }) do
    it(("keeps it on the file %s opens from the sidebar"):format(key), function()
      Sidebar.cursor_to(name .. ".lua")

      vim.cmd.normal(vim.keycode(key))

      assert.is_true(keeps(name))
    end)
  end

  it("keeps it on a file previewed once the cursor moves into the preview", function()
    Sidebar.cursor_to("preview.lua")

    vim.api.nvim_set_current_win(file_win)

    assert.is_true(keeps("preview"))
  end)

  it("keeps it on the file a walk opens", function()
    vim.api.nvim_win_set_cursor(assert(window.win()), { line_of("vsplit.lua"), 0 })

    changeset.step(1, "file")

    assert.is_true(vim.endswith(vim.api.nvim_buf_get_name(0), "walk.lua"))
    assert.is_true(keeps("walk"))
  end)

  it("keeps it on the file the picker opens", function()
    pick_file("chosen")

    assert.is_true(keeps("chosen"))
  end)

  it("keeps it on a file of the tree the cursor reaches another way, as by :edit", function()
    vim.cmd.edit("edit.lua")
    Sidebar.flush()

    assert.is_true(keeps("edit"))
  end)

  it("closes it on a file the sidebar only previewed as its cursor moved", function()
    Sidebar.cursor_to("browse.lua")

    assert.is_true(left_bare("browse"))
  end)

  it("closes it on a file ]g previewed in the window it was pressed in", function()
    vim.api.nvim_win_set_cursor(assert(window.win()), { line_of("step.lua") - 1, 0 })

    changeset.preview_step(1)
    Sidebar.flush()

    assert.is_true(vim.endswith(vim.api.nvim_buf_get_name(0), "step.lua"))
    assert.is_true(left_bare("step"))
  end)

  it("shows it on a file the picker opens with the sidebar closed", function()
    changeset.close()

    pick_file("found")

    assert.is_true(shows(window_of("found")))
  end)

  it("shows none on a file the picker opens with the diff off, though the file is entered", function()
    changeset.close()
    changeset.diff()

    pick_file("quiet")
    assert.is_true(left_bare("quiet"))
    changeset.diff()
    changeset.open()

    assert.is_true(keeps("quiet"))
  end)

  vim.ui.select, vim.notify = real_select, quiet
  config.setup()
  vim.cmd("silent! %bwipeout!")
  vim.fn.chdir(previous)
  vim.fn.delete(dir, "rf")
end)
