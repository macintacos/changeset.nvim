vim.opt.rtp:prepend(require("support.deps").path("mini.icons"))
require("mini.icons").setup()

local changeset = require("changeset")
local window = require("changeset.window")
local Fixture = require("support.git")

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

---The text of the float `?` opened, closing it.
local function help_text()
  local float = assert(vim.iter(vim.api.nvim_list_wins()):find(function(win)
    return vim.api.nvim_win_get_config(win).relative ~= ""
  end))
  local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false), "\n")
  vim.api.nvim_win_close(float, true)
  return text
end

---The keys the float `?` opened lists, closing it.
---@return string[]
local function help_keys()
  local keys = {}
  for line in help_text():gmatch("[^\n]+") do
    table.insert(keys, (assert(line:match("^(%S+)%s%s"), line)))
  end
  return keys
end

describe("changeset setup", function()
  local tmp, previous_dir

  before_each(function()
    tmp, previous_dir = Fixture.enter_tempdir()
    Fixture.feature_two_files(tmp)
  end)

  after_each(function()
    changeset.close()
    changeset.setup()
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
  end)

  it("binds every default sidebar key without setup()", function()
    local buf = open_sidebar()

    for action, lhs in pairs(require("changeset.config").get().keymaps) do
      if lhs then
        assert.not_nil(buffer_map(buf, lhs), action)
      end
    end
  end)

  it("binds a remapped key in place of the default, and ? lists it", function()
    changeset.setup({ keymaps = { jump = "o" } })
    local buf = open_sidebar()

    assert.not_nil(buffer_map(buf, "o"))
    assert.is_nil(buffer_map(buf, "<CR>"))
    press("?")
    local listed = help_keys()
    assert.is_true(vim.list_contains(listed, "o"))
    assert.is_false(vim.list_contains(listed, "<CR>"))
  end)

  it("leaves a false key unbound, and out of ?", function()
    changeset.setup({ keymaps = { refresh = false } })
    local buf = open_sidebar()

    assert.is_nil(buffer_map(buf, "R"))
    press("?")
    assert.is_false(vim.list_contains(help_keys(), "R"))
  end)

  it("lists under ? exactly the keys bound on the sidebar", function()
    local buf = open_sidebar()
    local bound = vim.tbl_map(function(keymap)
      return keymap.lhs
    end, vim.api.nvim_buf_get_keymap(buf, "n"))
    table.sort(bound)

    press("?")
    local listed = help_keys()
    table.sort(listed)

    assert.same(bound, listed)
  end)

  it("closes the tree on q", function()
    open_sidebar()

    press("q")

    assert.is_nil(window.win())
  end)

  it("opens the file and closes the tree on <S-CR>", function()
    local buf = open_sidebar()
    local lnum = vim.fn.match(lines_of(buf), [[other\.lua]]) + 1
    -- Entering the sidebar moves its cursor to the file being edited, so enter it before placing the cursor.
    vim.api.nvim_set_current_win((assert(window.win())))
    vim.api.nvim_win_set_cursor(0, { lnum, 0 })

    vim.cmd.normal(vim.keycode("<S-CR>"))

    assert.is_nil(window.win())
    assert.equal("other.lua", vim.fs.basename(vim.api.nvim_buf_get_name(0)))
  end)

  ---Presses `key` on other.lua's row; returns the screen positions of the window it opened and of the file's window.
  ---@param key string
  ---@return integer[] opened
  ---@return integer[] origin
  local function split_from_sidebar(key)
    local buf = open_sidebar()
    local origin = vim.fn.bufwinid("mod.lua")
    local lnum = vim.fn.match(lines_of(buf), [[other\.lua]]) + 1
    vim.api.nvim_set_current_win((assert(window.win())))
    vim.api.nvim_win_set_cursor(0, { lnum, 0 })

    vim.api.nvim_feedkeys(vim.keycode(key), "x", false)

    assert.equal("other.lua", vim.fs.basename(vim.api.nvim_buf_get_name(0)))
    return vim.fn.win_screenpos(0), vim.fn.win_screenpos(origin)
  end

  it("opens a row in a vertical split on <C-v>", function()
    local opened, origin = split_from_sidebar("<C-v>")

    assert.equal(origin[1], opened[1])
    assert.not_equal(origin[2], opened[2])
  end)

  it("opens a row in a split on <C-s>", function()
    local opened, origin = split_from_sidebar("<C-s>")

    assert.equal(origin[2], opened[2])
    assert.not_equal(origin[1], opened[1])
  end)

  it("searches the tree on /", function()
    local buf = open_sidebar()
    local win = assert(window.win())
    vim.api.nvim_set_current_win(win)

    vim.api.nvim_feedkeys(vim.keycode([[/other\.lua<CR>]]), "xt", false)

    assert.equal(win, vim.api.nvim_get_current_win())
    assert.truthy(lines_of(buf)[vim.api.nvim_win_get_cursor(win)[1]]:find("other.lua", 1, true))
  end)

  it("names the bound jump key in the footer", function()
    changeset.setup({ keymaps = { jump = "o" } })
    open_sidebar()

    local win = assert(window.win())
    local footer = vim.api.nvim_eval_statusline(vim.wo[win].statusline, { winid = win, maxwidth = 200 }).str
    assert.truthy(footer:find("o open", 1, true))
    assert.falsy(footer:find("<CR>", 1, true))
  end)

  it("applies a second setup() at the next open, not to the open sidebar", function()
    local buf = open_sidebar()
    changeset.setup({ keymaps = { jump = "o" } })

    assert.not_nil(buffer_map(buf, "<CR>"))
    assert.is_nil(buffer_map(buf, "o"))

    changeset.close()
    buf = open_sidebar()
    assert.is_nil(buffer_map(buf, "<CR>"))
    assert.not_nil(buffer_map(buf, "o"))
  end)
end)
