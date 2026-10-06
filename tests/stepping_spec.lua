local changeset = require("changeset")
-- The <Plug> maps live in the plugin file, which the spec runner does not load.
vim.cmd("runtime plugin/changeset.lua")
local Fixture = require("support.git")
local Sidebar = require("support.sidebar")
local comment_store = require("changeset.comment_store")
local window = require("changeset.window")

describe("changeset.step", function()
  local tmp, previous_dir, echoed, echo

  before_each(function()
    os.remove(comment_store.path())
    tmp, previous_dir = Fixture.enter_tempdir()
    Fixture.feature_numbered(tmp)
    echoed, echo = {}, vim.api.nvim_echo
    vim.api.nvim_echo = function(chunks)
      table.insert(echoed, chunks[1][1])
    end
  end)

  after_each(function()
    vim.api.nvim_echo = echo
    changeset.close()
    vim.cmd("silent! only")
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
    os.remove(comment_store.path())
  end)

  ---Edits `mod.lua` on line `lnum`, keeping a review comment on `other.lua:3`, so the sidebar's rows read:
  ---Comments, other.lua:3, Implementation, mod.lua, Other changes, L2, L8, other.lua, Other changes, L3.
  ---@param lnum integer
  ---@return integer win The file's window.
  local function edit(lnum)
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { lnum, 0 })
    comment_store.keep(vim.fs.normalize(assert(vim.uv.cwd())), { path = "other.lua", line = 3, body = "why" })
    return vim.api.nvim_get_current_win()
  end

  ---Waits for the tree's rows, every file's symbols read.
  local function settle()
    Sidebar.settle()
    assert(vim.wait(5000, function()
      local text = Sidebar.text()
      return text:find("L2", 1, true) and text:find("L3", 1, true) and not text:find("reading", 1, true)
    end))
  end

  ---@param win integer
  ---@return string file, integer line
  local function shown(win)
    local buf = vim.api.nvim_win_get_buf(win)
    return vim.fs.basename(vim.api.nvim_buf_get_name(buf)), vim.api.nvim_win_get_cursor(win)[1]
  end

  it("opens a closed sidebar without focus, then takes the step once the changes are read", function()
    local win = edit(2)

    changeset.step(1)
    assert.truthy(window.is_visible())
    assert.equal(win, vim.api.nvim_get_current_win())
    settle()

    -- The step runs as the diff lands, before any symbols: from mod.lua's row, the next place is other.lua's.
    assert.equal(win, vim.api.nvim_get_current_win())
    assert.same({ "other.lua", 3 }, { shown(win) })
    assert.is_nil(Sidebar.cursor_line():find("why", 1, true))
  end)

  it("takes only the last step pressed while the changes are read", function()
    local win = edit(2)

    changeset.step(1)
    changeset.step(-1)
    settle()

    -- From mod.lua's row, the previous place is the review comment's.
    assert.same({ "other.lua", 3 }, { shown(win) })
    assert.truthy(Sidebar.cursor_line():find("why", 1, true))
  end)

  it("drops a waiting step when the sidebar closes first", function()
    local win = edit(2)

    changeset.step(1)
    changeset.close()
    changeset.open()
    vim.api.nvim_set_current_win(win)
    settle()

    assert.same({ "mod.lua", 2 }, { shown(win) })
  end)

  it("steps over rows that open where you already are, counting places", function()
    local win = edit(2)
    changeset.open()
    settle()
    Sidebar.cursor_to("Other changes")
    vim.api.nvim_set_current_win(win)

    changeset.step(1)
    assert.same({ "mod.lua", 8 }, { shown(win) })
    changeset.step(-1)
    assert.same({ "mod.lua", 2 }, { shown(win) })
    assert.truthy(Sidebar.cursor_line():find("L2", 1, true))
    changeset.step(2)

    assert.equal(win, vim.api.nvim_get_current_win())
    assert.same({ "other.lua", 3 }, { shown(win) })
    assert.truthy(Sidebar.cursor_line():find("other.lua", 1, true))
  end)

  it("steps over section headers onto a Comments row, opening its line but not the review comment", function()
    local win = edit(1)
    changeset.open()
    settle()
    Sidebar.cursor_to("mod.lua")
    vim.api.nvim_set_current_win(win)
    local wins = #vim.api.nvim_list_wins()

    changeset.step(-1)

    assert.same({ "other.lua", 3 }, { shown(win) })
    assert.equal(wins, #vim.api.nvim_list_wins())
  end)

  it("stays put, and says so, when no row past it opens anywhere new", function()
    local win = edit(2)
    changeset.open()
    settle()
    Sidebar.cursor_to("L3")
    vim.api.nvim_set_current_win(win)
    local before = vim.api.nvim_win_get_cursor(window.win() or 0)[1]

    changeset.step(1)

    assert.same({ "other.lua", 3 }, { shown(win) })
    assert.equal(before, vim.api.nvim_win_get_cursor(window.win() or 0)[1])
    assert.equal(1, #echoed)
  end)

  it("opens the row in the window the sidebar opens changes in, keeping focus on the sidebar", function()
    local win = edit(2)
    changeset.toggle()
    settle()
    local sidebar = assert(window.win())
    Sidebar.cursor_to("L2")

    changeset.step(1)

    assert.equal(sidebar, vim.api.nvim_get_current_win())
    assert.same({ "mod.lua", 8 }, { shown(win) })
  end)

  describe("through <Plug>(changeset-next) and .", function()
    it("repeats the step from your window as each jump changes its file", function()
      local win = edit(2)
      changeset.open()
      settle()
      Sidebar.cursor_to("Other changes")
      vim.api.nvim_set_current_win(win)

      vim.api.nvim_feedkeys(vim.keycode("<Plug>(changeset-next)"), "x", false)
      assert.same({ "mod.lua", 8 }, { shown(win) })
      vim.api.nvim_feedkeys(".", "x", false)
      assert.same({ "other.lua", 3 }, { shown(win) })
      vim.api.nvim_feedkeys("2" .. vim.keycode("<Plug>(changeset-prev)"), "x", false)
      assert.same({ "mod.lua", 2 }, { shown(win) })
      vim.api.nvim_feedkeys(".", "x", false)

      assert.equal(win, vim.api.nvim_get_current_win())
      assert.same({ "other.lua", 3 }, { shown(win) })
      assert.truthy(Sidebar.cursor_line():find("other.lua:3", 1, true))
    end)

    it("repeats the step from the sidebar", function()
      local win = edit(2)
      changeset.toggle()
      settle()
      Sidebar.cursor_to("mod.lua")

      vim.api.nvim_feedkeys(vim.keycode("<Plug>(changeset-next)") .. ".", "x", false)

      -- The mod.lua row previews line 1, so the steps open Other changes, then L8.
      assert.equal(window.win(), vim.api.nvim_get_current_win())
      assert.same({ "mod.lua", 8 }, { shown(win) })
      Sidebar.flush()
      assert.equal("", vim.wo[win].winbar)
    end)
  end)
end)
