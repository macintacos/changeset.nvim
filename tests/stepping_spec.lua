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

    -- Taken once mod.lua's symbols are read, so its rows are its changes: L2 opens where you are, L8 is next.
    assert.equal(win, vim.api.nvim_get_current_win())
    assert.same({ "mod.lua", 8 }, { shown(win) })
  end)

  it("never steps backwards from a cold press past your file's last change", function()
    local win = edit(8)

    changeset.step(1)
    settle()

    assert.same({ "other.lua", 3 }, { shown(win) })
  end)

  it("adds up presses made while the changes are read, a press the other way taking one off", function()
    local win = edit(2)

    changeset.step(1)
    changeset.step(1)
    changeset.step(-1)
    settle()

    assert.same({ "mod.lua", 8 }, { shown(win) })
  end)

  it("drops a waiting step once you have moved to another buffer", function()
    local win = edit(2)

    changeset.step(1)
    vim.cmd.edit("other.lua")
    settle()

    assert.same({ "other.lua", 1 }, { shown(win) })
  end)

  it("drops a waiting step when the diff fails to read", function()
    local win = edit(2)
    local diff = require("changeset.diff")
    local collect = diff.collect
    local failed = false
    diff.collect = function(_, _, done)
      diff.collect = collect
      vim.schedule(function()
        done(nil, "simulated failure")
        failed = true
      end)
    end
    local notify = vim.notify
    vim.notify = function() end

    changeset.step(1)
    assert(vim.wait(2000, function()
      return failed
    end))
    require("changeset.build").refresh()
    settle()

    vim.notify = notify
    assert.same({ "mod.lua", 2 }, { shown(win) })
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

  describe("from a line between the sidebar's rows", function()
    ---Opens the sidebar on `row`, then puts your window on `file`, line `lnum`, the sidebar left where it was.
    ---@param row string
    ---@param file string
    ---@param lnum integer
    ---@return integer win
    local function stand(row, file, lnum)
      local win = edit(2)
      changeset.open()
      settle()
      Sidebar.cursor_to(row)
      vim.api.nvim_set_current_win(win)
      vim.cmd("buffer " .. file)
      vim.api.nvim_win_set_cursor(win, { lnum, 0 })
      return win
    end

    it("goes back to the change above, not past it", function()
      local win = stand("L8", "mod.lua", 10)

      changeset.step(-1)

      assert.same({ "mod.lua", 8 }, { shown(win) })
    end)

    it("goes on to the file's first change from above it", function()
      local win = stand("L2", "mod.lua", 1)
      vim.api.nvim_win_set_cursor(win, { 1, 0 })

      changeset.step(1)

      assert.same({ "mod.lua", 2 }, { shown(win) })
    end)

    it("goes back past the file from above its first change, never down", function()
      local win = stand("L2", "mod.lua", 1)

      changeset.step(-1)

      assert.same({ "other.lua", 3 }, { shown(win) })
    end)

    it("starts from your file, not the sidebar's row in another", function()
      local win = stand("L3", "mod.lua", 1)

      changeset.step(1)

      assert.same({ "mod.lua", 2 }, { shown(win) })
    end)
  end)

  it("lands on your row next time you enter the sidebar, after a step from it opened nothing", function()
    local win = edit(8)
    changeset.toggle()
    settle()
    Sidebar.cursor_to("L8")
    -- Gone from disk before the tree hears of it, so the step onto its row can't open it.
    os.remove("other.lua")
    local notify = vim.notify
    vim.notify = function() end

    changeset.step(1)
    vim.notify = notify
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { 2, 0 })
    local sidebar = window.win() or 0
    vim.api.nvim_set_current_win(sidebar)

    -- Off the row the failed step left it on, onto mod.lua's own.
    assert.is_nil(Sidebar.cursor_line():find("other.lua", 1, true))
  end)

  it("drops a waiting step taken while the sidebar is on another tabpage", function()
    local win = edit(2)

    changeset.step(1)
    vim.cmd.tabnew()
    assert(vim.wait(5000, function()
      local tree = require("changeset.build").current()
      return tree ~= nil and tree.collected and not Sidebar.text():find("reading", 1, true)
    end))
    vim.cmd.tabprevious()
    vim.api.nvim_win_set_cursor(win, { 5, 0 })
    require("changeset.build").refresh()
    settle()

    assert.same({ "mod.lua", 5 }, { shown(win) })
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

  it("steps over a deleted file's row, which opens nowhere", function()
    local win = edit(2)
    Fixture.git({ "rm", "-q", "plain.lua" }, tmp)
    Fixture.commit("drop plain.lua", tmp)
    changeset.open()
    settle()
    Sidebar.cursor_to("L3")
    vim.api.nvim_set_current_win(win)
    local notify, notes = vim.notify, {}
    vim.notify = function(msg)
      table.insert(notes, msg)
    end

    changeset.step(1)

    vim.notify = notify
    assert.same({}, notes)
    assert.same({ "no next change" }, echoed)
    assert.same({ "other.lua", 3 }, { shown(win) })
  end)

  it("opens the row in the window the sidebar opens changes in, keeping focus on the sidebar", function()
    local win = edit(2)
    changeset.toggle()
    settle()
    local sidebar = assert(window.win())
    Sidebar.cursor_to("L8")
    local left = {}
    vim.api.nvim_create_autocmd("WinLeave", {
      group = vim.api.nvim_create_augroup("stepping_spec", {}),
      callback = function()
        left[vim.api.nvim_get_current_win()] = true
      end,
    })

    changeset.step(1)
    -- The main loop fires this once the sidebar's cursor has moved; a spec has to.
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = window.buf() })
    Sidebar.flush()

    vim.api.nvim_del_augroup_by_name("stepping_spec")
    assert.equal(sidebar, vim.api.nvim_get_current_win())
    assert.same({ "other.lua", 3 }, { shown(win) })
    assert.equal("", vim.wo[win].winbar)
    assert.truthy(left[win])
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
    end)
  end)
end)
