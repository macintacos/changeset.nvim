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
local present = require("support.present")

---Put the sidebar's cursor on the first line containing `text`. Headless, setting a
---cursor fires no `CursorMoved`, so this stands in for the user moving it without a preview.
---@param text string
local function park_sidebar_cursor(text)
  for i, line in ipairs(Sidebar.lines()) do
    if line:find(text, 1, true) then
      vim.api.nvim_win_set_cursor(present(window.win()), { i, 0 })
      return
    end
  end
  error("no sidebar line contains " .. text)
end

describe("changeset sidebar focus", function()
  local tmp ---@type string
  local previous_dir ---@type string

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

    local win = present(window.win())
    vim.api.nvim_set_current_win(win)

    assert.truthy((Sidebar.cursor_line():find("Other changes", 1, true)))
  end)

  it("only focuses the sidebar on a click from another window, landing on the row you are on", function()
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    changeset.open()
    Sidebar.settle()

    Sidebar.click("other.lua")

    assert.equal(window.win(), vim.api.nvim_get_current_win())
    assert.truthy((Sidebar.cursor_line():find("Other changes", 1, true)))
  end)

  it("keeps the cursor on a landed row that you expand", function()
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    changeset.open()
    Sidebar.settle()
    local win = present(window.win())
    vim.api.nvim_set_current_win(win)
    park_sidebar_cursor("mod.lua")
    vim.cmd.normal("h")
    vim.cmd.wincmd("p")
    Sidebar.flush()
    changeset.toggle()

    vim.cmd.normal("l")

    assert.truthy((Sidebar.cursor_line():find("mod.lua", 1, true)))
  end)

  it("steps from where the cursor is when the sidebar is the only window", function()
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    changeset.toggle()
    Sidebar.settle()
    park_sidebar_cursor("other.lua")
    local win = present(window.win())
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
    assert.truthy((Sidebar.cursor_line():find("other.lua", 1, true)))
  end)

  describe("while symbols are still being read", function()
    local source ---@type support.symbols.Source
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
      assert.truthy((Sidebar.cursor_line():find("mod.lua", 1, true)))

      answer("mod.lua", { Changes.sym("step", "Function", 0, 7, 9) })

      assert.truthy((Sidebar.cursor_line():find("step", 1, true)))
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

  describe("given a buffer in its window", function()
    ---The name of the file `win` shows.
    ---@param win integer
    ---@return string
    local function file_in(win)
      return vim.fs.basename(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)))
    end

    ---Where the tree, the cursor and the file stand once the editor is idle again.
    ---@param sidebar integer
    ---@param file_win integer
    ---@return table
    local function settled(sidebar, file_win)
      vim.api.nvim_exec_autocmds("SafeState", {})
      return {
        tree = vim.api.nvim_win_get_buf(sidebar),
        focus = vim.api.nvim_get_current_win(),
        file = file_in(file_win),
        cursor = vim.api.nvim_win_get_cursor(file_win),
      }
    end

    it("opens the file :edit put there in the window the cursor came from, at its line", function()
      vim.cmd.edit("mod.lua")
      local file_win = vim.api.nvim_get_current_win()
      changeset.open()
      Sidebar.settle()
      local win, tree = present(window.win()), present(window.buf())
      vim.api.nvim_set_current_win(win)

      vim.cmd.edit("+3 other.lua")

      assert.same({ tree = tree, focus = file_win, file = "other.lua", cursor = { 3, 0 } }, settled(win, file_win))
    end)

    it("keeps the tree in its window and follows <C-o> back to the window the cursor came from", function()
      vim.cmd.edit("plain.lua")
      vim.cmd.edit("mod.lua")
      local file_win = vim.api.nvim_get_current_win()
      changeset.open()
      Sidebar.settle()
      local win, tree = present(window.win()), present(window.buf())
      vim.api.nvim_set_current_win(win)

      vim.cmd.normal({ args = { vim.keycode("<C-o>") }, bang = true })

      local landed = settled(win, file_win)
      assert.same({ tree = tree, focus = file_win }, { tree = landed.tree, focus = landed.focus })
    end)

    it("opens what a picker put there in the window the cursor left for the sidebar, not the picker", function()
      vim.cmd.edit("mod.lua")
      local file_win = vim.api.nvim_get_current_win()
      -- Ahead of it in the layout, so the first window that could hold a file is not the one the cursor came from.
      vim.cmd("leftabove vsplit plain.lua")
      vim.api.nvim_set_current_win(file_win)
      changeset.open()
      Sidebar.settle()
      local win, tree = present(window.win()), present(window.buf())
      vim.api.nvim_set_current_win(win)
      -- A picker's prompt, which hands focus back to the sidebar before it closes.
      local prompt = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
        relative = "editor",
        row = 1,
        col = 1,
        width = 20,
        height = 3,
      })
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_close(prompt, true)

      vim.api.nvim_win_set_buf(win, vim.fn.bufadd("other.lua"))
      vim.api.nvim_win_set_cursor(win, { 3, 2 })

      assert.same({ tree = tree, focus = file_win, file = "other.lua", cursor = { 3, 2 } }, settled(win, file_win))
    end)

    it("shows the cursor again in the window the buffer moves to", function()
      vim.cmd.edit("mod.lua")
      local file_win = vim.api.nvim_get_current_win()
      changeset.open()
      Sidebar.settle()
      local win = present(window.win())
      vim.api.nvim_set_current_win(win)

      vim.cmd.edit("other.lua")
      settled(win, file_win)

      assert.is_false(Cursor.hidden())
    end)

    it("keeps a buffer that wipes itself once hidden", function()
      vim.cmd.edit("mod.lua")
      local file_win = vim.api.nvim_get_current_win()
      changeset.open()
      Sidebar.settle()
      local win = present(window.win())
      vim.api.nvim_set_current_win(win)
      local scratch = vim.api.nvim_create_buf(false, true)
      vim.bo[scratch].bufhidden = "wipe"

      vim.api.nvim_win_set_buf(win, scratch)
      settled(win, file_win)

      assert.equal(scratch, vim.api.nvim_win_get_buf(file_win))
    end)
  end)

  it("opens a new sidebar on toggle() from a window another buffer took from the tree", function()
    vim.cmd.edit("mod.lua")
    changeset.open()
    Sidebar.settle()
    local win = present(window.win())
    vim.api.nvim_set_current_win(win)
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
