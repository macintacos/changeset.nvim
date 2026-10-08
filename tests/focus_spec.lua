local changeset = require("changeset")
-- The <Plug> maps live in the plugin file, which the spec runner does not load.
vim.cmd("runtime plugin/changeset.lua")
-- What `]g` runs: the spec runner starts before startup is done, which maps the default keys.
local PREVIEW_NEXT = vim.keycode("<Plug>(changeset-preview-next)")
local window = require("changeset.window")
local Changes = require("support.changes")
local Fixture = require("support.git")
local Cursor = require("support.cursor")
local Sidebar = require("support.sidebar")
local Symbols = require("support.symbols")

---Put the sidebar's cursor on the first line containing `text`. Headless, setting a
---cursor fires no `CursorMoved`, so this stands in for the user moving it without a preview.
---@param text string
local function park_sidebar_cursor(text)
  for i, line in ipairs(Sidebar.lines()) do
    if line:find(text, 1, true) then
      vim.api.nvim_win_set_cursor(assert(window.win()), { i, 0 })
      return
    end
  end
  error("no sidebar line contains " .. text)
end

describe("changeset sidebar focus", function()
  local tmp, previous_dir

  -- The tree resolves its repo from the current buffer, which falls back to the
  -- process cwd, and the cases edit relative paths, so it has to be entered.
  before_each(function()
    tmp, previous_dir = Fixture.enter_tempdir()
    Fixture.feature_numbered(tmp)
  end)

  after_each(function()
    changeset.close()
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
  end)

  it("lands on the row you are on when focus arrives by a route other than toggle()", function()
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    changeset.open()
    Sidebar.settle()
    park_sidebar_cursor("other.lua")

    local win = assert(window.win())
    vim.api.nvim_set_current_win(win)

    assert.truthy(Sidebar.cursor_line():find("Other changes", 1, true))
  end)

  it("only focuses the sidebar on a click from another window, landing on the row you are on", function()
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    changeset.open()
    Sidebar.settle()

    Sidebar.click("other.lua")

    assert.equal(window.win(), vim.api.nvim_get_current_win())
    assert.truthy(Sidebar.cursor_line():find("Other changes", 1, true))
  end)

  it("keeps the cursor on a landed row that you expand", function()
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    changeset.open()
    Sidebar.settle()
    local win = assert(window.win())
    vim.api.nvim_set_current_win(win)
    park_sidebar_cursor("mod.lua")
    vim.cmd.normal("h")
    vim.cmd.wincmd("p")
    Sidebar.flush()
    changeset.toggle()

    vim.cmd.normal("l")

    assert.truthy(Sidebar.cursor_line():find("mod.lua", 1, true))
  end)

  it("steps from where the cursor is when the sidebar is the only window", function()
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    changeset.toggle()
    Sidebar.settle()
    park_sidebar_cursor("other.lua")
    local win = assert(window.win())
    local parked = vim.api.nvim_win_get_cursor(win)[1]
    vim.cmd.only()

    vim.cmd.normal(PREVIEW_NEXT)

    assert.equal(parked + 1, vim.api.nvim_win_get_cursor(win)[1])
  end)

  it("leaves the cursor alone when a float entered from the sidebar closes", function()
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    changeset.toggle()
    Sidebar.settle()
    park_sidebar_cursor("other.lua")
    local float = vim.api.nvim_open_win(
      vim.api.nvim_create_buf(false, true),
      true,
      { relative = "editor", row = 1, col = 1, width = 10, height = 2 }
    )

    vim.api.nvim_win_close(float, true)

    assert.equal(window.win(), vim.api.nvim_get_current_win())
    assert.truthy(Sidebar.cursor_line():find("other.lua", 1, true))
  end)

  describe("while symbols are still being read", function()
    local source
    ---@type fun(path: string, items: table[]?)
    local answer

    before_each(function()
      source = Symbols.install()
      answer = source.answer
    end)

    after_each(function()
      source.restore()
    end)

    it("lands on the file row, then follows you into your symbol once it resolves", function()
      vim.cmd.edit("mod.lua")
      vim.api.nvim_win_set_cursor(0, { 8, 0 })
      changeset.toggle()
      Sidebar.await_diff()
      assert.truthy(Sidebar.cursor_line():find("mod.lua", 1, true))

      answer("mod.lua", { Changes.sym("step", "Function", 0, 7, 9) })

      assert.truthy(Sidebar.cursor_line():find("step", 1, true))
    end)
  end)

  it("hides the cursor while focus is in the sidebar", function()
    vim.cmd.edit("mod.lua")
    changeset.toggle()
    Sidebar.settle()

    assert.is_true(Cursor.hidden())
  end)

  it("shows the cursor once focus leaves the sidebar", function()
    vim.cmd.edit("mod.lua")
    changeset.toggle()
    Sidebar.settle()

    vim.cmd.wincmd("p")

    assert.is_false(Cursor.hidden())
  end)

  it("shows the cursor once the focused sidebar closes", function()
    vim.cmd.edit("mod.lua")
    changeset.toggle()
    Sidebar.settle()

    changeset.close()

    assert.is_false(Cursor.hidden())
  end)

  it("keeps the tree in its window when <C-o> jumps back from the focused sidebar", function()
    vim.cmd.edit("plain.lua")
    vim.cmd.edit("mod.lua")
    changeset.open()
    Sidebar.settle()
    local win, tree = assert(window.win()), assert(window.buf())
    vim.api.nvim_set_current_win(win)

    pcall(vim.cmd.normal, { args = { vim.keycode("<C-o>") }, bang = true })

    assert.equal(tree, vim.api.nvim_win_get_buf(win))
  end)

  it("opens a new sidebar on toggle() from a window another buffer took from the tree", function()
    vim.cmd.edit("mod.lua")
    changeset.open()
    Sidebar.settle()
    local win = assert(window.win())
    vim.api.nvim_set_current_win(win)
    vim.wo[win].winfixbuf = false
    vim.cmd.edit("other.lua")

    changeset.toggle()

    assert.is_true(vim.api.nvim_win_is_valid(win))
    assert.not_equal(win, window.win())
  end)

  it("closes the focused sidebar on toggle() and hands focus back", function()
    vim.cmd.edit("mod.lua")
    local file_win = vim.api.nvim_get_current_win()
    changeset.toggle()
    Sidebar.settle()

    changeset.toggle()

    assert.is_nil(window.win())
    assert.equal(file_win, vim.api.nvim_get_current_win())
  end)
end)
