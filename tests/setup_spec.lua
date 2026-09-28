vim.opt.rtp:prepend(require("support.deps").path("mini.icons"))
require("mini.icons").setup()

local changeset = require("changeset")
local window = require("changeset.window")
local Fixture = require("support.git")

---@param path string
---@param lines string[]
local function write(path, lines)
  vim.fn.writefile(lines, path)
end

---A repo on `trunk` with two files, then a `feature` branch that changes both.
---@param cwd string
local function init_feature_repo(cwd)
  Fixture.init_repo("trunk", cwd)

  write("mod.lua", { "local M = {}", "", "function M.one()", "  return 1", "end", "", "return M" })
  write("other.lua", { "return { a = 1 }" })
  Fixture.commit("base", cwd)

  Fixture.git({ "checkout", "-q", "-b", "feature" }, cwd)
  write("mod.lua", { "local M = {}", "", "function M.one()", "  return 2", "end", "", "return M" })
  write("other.lua", { "return { a = 1, b = 2 }" })
  Fixture.commit("change", cwd)
end

---@param buf integer
---@return string[]
local function lines_of(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---@return integer buf
local function open_sidebar()
  vim.cmd.edit("mod.lua")
  changeset.open()
  local buf
  vim.wait(10000, function()
    buf = window.buf()
    return buf ~= nil and #lines_of(buf) > 1
  end, 25)
  assert(buf, "the sidebar never opened a buffer")

  local settled = vim.wait(10000, function()
    return not table.concat(lines_of(buf), "\n"):find("reading symbols", 1, true)
  end, 25)
  assert(settled, "symbols never finished resolving")
  return buf
end

---@param key string
local function press(key)
  local win = assert(window.win())
  vim.api.nvim_set_current_win(win)
  vim.cmd.normal(key)
end

---The sidebar buffer's own normal-mode mapping for `lhs`, if any.
local function buffer_map(buf, lhs)
  return vim.iter(vim.api.nvim_buf_get_keymap(buf, "n")):find(function(keymap)
    return vim.keycode(keymap.lhs) == vim.keycode(lhs)
  end)
end

---The global normal-mode mapping for `lhs`, if any.
local function global_map(lhs)
  return vim.iter(vim.api.nvim_get_keymap("n")):find(function(keymap)
    return vim.keycode(keymap.lhs) == vim.keycode(lhs)
  end)
end

---The text of the float `?` opened, closing it.
local function help_text()
  local float = assert(vim.iter(vim.api.nvim_list_wins()):find(function(win)
    return vim.api.nvim_win_get_config(win).relative ~= ""
  end))
  local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false), "\n")
  vim.api.nvim_win_close(float, true)
  return text
end

describe("changeset setup", function()
  local tmp, previous_dir

  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    previous_dir = vim.fn.chdir(tmp)
    assert(previous_dir ~= "", "could not enter the fixture directory")

    init_feature_repo(tmp)
  end)

  after_each(function()
    changeset.close()
    changeset.setup()
    pcall(vim.keymap.del, "n", "]h")
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
  end)

  it("binds today's sidebar keys and no step keys without setup()", function()
    local buf = open_sidebar()

    local defaults =
      { "<CR>", "<S-CR>", "q", "h", "l", "H", "L", "]]", "[[", "F", "f", "R", "y", "/", "-", "<C-t>", "?" }
    for _, lhs in ipairs(defaults) do
      assert.is_not_nil(buffer_map(buf, lhs), lhs)
    end
    assert.is_nil(global_map("]h"))
    assert.is_nil(global_map("[h"))
  end)

  it("binds a remapped key in place of the default, and ? lists it", function()
    changeset.setup({ keymaps = { jump = "o" } })
    local buf = open_sidebar()

    assert.equal("Go to this change", buffer_map(buf, "o").desc)
    assert.is_nil(buffer_map(buf, "<CR>"))
    press("?")
    local text = help_text()
    assert.truthy(text:match("o%s+Go to this change"))
    assert.falsy(text:find("<CR>", 1, true))
  end)

  it("leaves a false key unbound, and out of ?", function()
    changeset.setup({ keymaps = { refresh = false } })
    local buf = open_sidebar()

    assert.is_nil(buffer_map(buf, "R"))
    press("?")
    assert.falsy(help_text():find("Rebuild the tree", 1, true))
  end)

  it("binds next/prev while open, then puts back the user's mapping", function()
    vim.keymap.set("n", "]h", function() end, { desc = "user ]h" })
    changeset.setup({ keymaps = { next = "]h", prev = "[h" } })
    open_sidebar()

    assert.equal("Next change (Changeset)", global_map("]h").desc)
    assert.equal("Previous change (Changeset)", global_map("[h").desc)
    press("?")
    assert.truthy(help_text():match("%]h%s+Next change"))

    changeset.close()
    changeset.close()
    assert.equal("user ]h", global_map("]h").desc)
    assert.is_nil(global_map("[h"))
  end)

  it("applies a second setup() at the next open, not to the open sidebar", function()
    local buf = open_sidebar()
    changeset.setup({ keymaps = { jump = "o" } })

    assert.is_not_nil(buffer_map(buf, "<CR>"))
    assert.is_nil(buffer_map(buf, "o"))

    changeset.close()
    buf = open_sidebar()
    assert.is_nil(buffer_map(buf, "<CR>"))
    assert.is_not_nil(buffer_map(buf, "o"))
  end)
end)
