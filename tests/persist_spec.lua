local changeset = require("changeset")
local highlights = require("changeset.highlights")
local Rows = require("changeset.rows")
local window = require("changeset.window")
local Changes = require("support.changes")
local Fixture = require("support.git")
local Notify = require("support.notify")
local Cursor = require("support.cursor")
local Sidebar = require("support.sidebar")
local Symbols = require("support.symbols")

local function focus_terminal()
  vim.cmd("new")
  -- No process: wiping a :terminal before its shell execs can SIGHUP this nvim.
  vim.api.nvim_open_term(0, {})
end

---The id of the Implementation row for `path`, or for the symbol chain under it.
---@param path string
---@param ... string Symbol names, outermost first.
---@return string
local function row_id(path, ...)
  return table.concat({ Rows.section_id("implementation"), path, ... }, "\0")
end

---Restore as a session read does: a leftover sidebar window, the recorded global, then
---`SessionLoadPost`'s refill. Focus stays where it was unless `focused`.
---@param position table|string A position, or the global's raw value.
---@param focused boolean? Whether the session left the sidebar focused.
local function restore_session(position, focused)
  local leftover = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(leftover, "changeset://tree")
  vim.api.nvim_open_win(leftover, focused or false, { split = "right", win = -1, width = 44 })
  vim.g.ChangesetPosition = type(position) == "string" and position or vim.json.encode(position)
  changeset.restore()
end

describe("changeset position in a session", function()
  local tmp, previous_dir

  -- The tree resolves its repo from the current buffer, which falls back to the
  -- process cwd, and the cases edit relative paths, so it has to be entered.
  before_each(function()
    tmp, previous_dir = Fixture.enter_tempdir()
    Fixture.feature_numbered(tmp)
    vim.g.ChangesetPosition = nil
  end)

  after_each(function()
    changeset.close()
    vim.cmd("silent! only")
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
    vim.g.ChangesetPosition = nil
  end)

  it("keeps where you are while focus sits in a terminal", function()
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    changeset.open()
    Sidebar.settle()

    focus_terminal()
    Sidebar.flush()

    assert.same({ path = "mod.lua", lnum = 8 }, vim.json.decode(vim.g.ChangesetPosition).here)
  end)

  it("keeps where you are while focus sits in a help window", function()
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    changeset.open()
    Sidebar.settle()

    vim.cmd.help("help")
    Sidebar.flush()

    assert.same({ path = "mod.lua", lnum = 8 }, vim.json.decode(vim.g.ChangesetPosition).here)
  end)

  it("keeps recording the sidebar's row while the cursor moves in another tabpage", function()
    vim.cmd.edit("mod.lua")
    changeset.open()
    Sidebar.settle()
    Sidebar.cursor_to("other.lua")
    Sidebar.flush()

    vim.cmd.tabnew()
    vim.cmd.edit("mod.lua")
    Sidebar.flush()
    local recorded = vim.json.decode(vim.g.ChangesetPosition)
    vim.cmd("silent! tabonly!")

    assert.equal("other.lua", recorded.row.path)
  end)

  it("restores where you were and the sidebar's cursor row from what it recorded", function()
    vim.cmd.edit("mod.lua")
    local file_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    changeset.open()
    Sidebar.settle()
    Sidebar.cursor_to("other.lua")
    Sidebar.flush()
    local recorded = vim.g.ChangesetPosition
    changeset.close()
    vim.api.nvim_set_current_win(file_win)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    Sidebar.flush()
    focus_terminal()

    restore_session(recorded)
    Sidebar.settle()
    Sidebar.flush()

    assert.truthy(Sidebar.line_with(highlights.HERE_HL):find("Other changes", 1, true))
    assert.truthy(Sidebar.cursor_line():find("other.lua", 1, true))
  end)

  it("brings the sidebar back scrolled as it was", function()
    vim.cmd.edit("mod.lua")
    changeset.open()
    Sidebar.settle()
    Sidebar.cursor_to("L8")
    local win = assert(window.win())
    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview({ topline = lnum - 1 })
    end)
    -- Neovim fires WinScrolled from its main loop, which a spec never reaches.
    vim.api.nvim_exec_autocmds("WinScrolled", { group = "changeset.track", pattern = tostring(win) })
    Sidebar.flush()
    local recorded = vim.g.ChangesetPosition
    changeset.close()
    focus_terminal()

    restore_session(recorded)
    Sidebar.settle()
    Sidebar.flush()

    assert.truthy(Sidebar.cursor_line():find("L8", 1, true))
    assert.equal(lnum - 1, vim.fn.line("w0", window.win()))
  end)

  it("keeps the sidebar's window options out of a session laid out while it has focus", function()
    local function options()
      local wo = vim.wo[0]
      return { wo.winfixwidth, wo.signcolumn, wo.wrap, wo.statusline }
    end
    vim.cmd.edit("mod.lua")
    local before = options()
    changeset.open()
    Sidebar.settle()
    local sidebar = assert(window.win())
    vim.api.nvim_set_current_win(sidebar)

    -- How a session file starts: it closes every window but the focused one and opens its first file there.
    vim.api.nvim_exec_autocmds("SessionLoadPre", {})
    vim.cmd("silent only")
    vim.cmd.edit("plain.lua")

    assert.same(before, options())
  end)

  it("keeps the sidebar a session refills over an open one", function()
    vim.cmd.edit("mod.lua")
    changeset.open()
    Sidebar.settle()
    local autocmds = #vim.api.nvim_get_autocmds({ group = "changeset" })

    -- As `:restart` does under a config that reads its own session at VimEnter: the
    -- second read's `only` closes the first one's sidebar before laying out its own.
    vim.cmd("silent only")
    restore_session({ here = { path = "mod.lua", lnum = 8 } })
    Sidebar.flush()

    assert.is_true(window.is_visible())
    assert.equal(autocmds, #vim.api.nvim_get_autocmds({ group = "changeset" }))
  end)

  it("hides the cursor when a session reopens the sidebar with focus in it", function()
    vim.cmd.edit("mod.lua")

    restore_session({ here = { path = "mod.lua", lnum = 8 } }, true)

    assert.equal(window.win(), vim.api.nvim_get_current_win())
    assert.is_true(Cursor.hidden())
  end)

  it("carries the recorded position through :mksession", function()
    local sessionoptions = vim.o.sessionoptions
    vim.o.sessionoptions = "blank,buffers,curdir,winsize,globals,terminal"
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    changeset.open()
    Sidebar.settle()
    Sidebar.cursor_to("L2")
    focus_terminal()
    Sidebar.flush()
    local recorded = vim.g.ChangesetPosition
    assert(recorded:find("\\u0000", 1, true), "the recorded row id should hold a NUL")
    vim.cmd("mksession! " .. vim.fn.fnameescape(tmp .. "/Session.vim"))
    vim.o.sessionoptions = sessionoptions
    vim.g.ChangesetPosition = nil

    -- Only the global's own line: sourcing the whole file would rebuild its layout
    -- on top of the specs that follow.
    for _, line in ipairs(vim.fn.readfile(tmp .. "/Session.vim")) do
      if line:find("^let ChangesetPosition") then
        vim.cmd(line)
      end
    end

    assert.equal(recorded, vim.g.ChangesetPosition)
  end)

  it("settles a recorded row on a file the branch deletes, then follows you again", function()
    Fixture.git({ "rm", "-q", "plain.lua" }, tmp)
    Fixture.commit("delete", tmp)
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local file_win = vim.api.nvim_get_current_win()
    focus_terminal()

    restore_session({ row = { id = row_id("plain.lua"), path = "plain.lua" } })
    Sidebar.settle()
    Sidebar.flush()

    assert.truthy(Sidebar.cursor_line():find("plain.lua", 1, true))
    vim.api.nvim_set_current_win(file_win)
    Sidebar.flush()
    assert.same({ path = "mod.lua", lnum = 2 }, vim.json.decode(vim.g.ChangesetPosition).here)
  end)

  it("closes a restored sidebar window it cannot fill", function()
    local outside = vim.fn.tempname()
    vim.fn.mkdir(outside, "p")
    vim.fn.chdir(outside)
    local before = #vim.api.nvim_tabpage_list_wins(0)
    local _, restore_notify = Notify.capture()

    local ok, err = pcall(restore_session, { here = { path = "mod.lua", lnum = 8 } })
    restore_notify()
    vim.fn.chdir(tmp)
    vim.fn.delete(outside, "rf")
    assert(ok, err)
    assert.equal(before, #vim.api.nvim_tabpage_list_wins(0))
  end)

  it("lets go of a restored sidebar window it cannot fill when it is the only window, and of its buffer", function()
    local outside = vim.fn.tempname()
    vim.fn.mkdir(outside, "p")
    vim.fn.chdir(outside)
    vim.cmd("enew")
    vim.api.nvim_buf_set_name(0, "changeset://tree")
    local stale = vim.api.nvim_get_current_buf()
    local _, restore_notify = Notify.capture()

    local ok, err = pcall(changeset.restore)
    restore_notify()
    vim.fn.chdir(tmp)
    vim.fn.delete(outside, "rf")

    assert(ok, err)
    assert.is_false(vim.api.nvim_buf_is_valid(stale))
  end)

  it(
    "fills a restored sidebar window standing in another tabpage, and leaves focus where the session put it",
    function()
      vim.cmd("runtime plugin/changeset.lua")
      vim.cmd.edit("mod.lua")
      local first = vim.api.nvim_get_current_tabpage()
      vim.cmd("tabnew")
      vim.cmd.edit("mod.lua")
      local leftover = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(leftover, "changeset://tree")
      local placeholder = vim.api.nvim_open_win(leftover, false, { split = "right", win = -1, width = 44 })
      vim.api.nvim_set_current_tabpage(first)

      vim.api.nvim_exec_autocmds("SessionLoadPost", {})
      local seen = { tab = vim.api.nvim_get_current_tabpage(), shown = vim.api.nvim_win_get_buf(placeholder) }
      local tree = window.buf()
      vim.cmd("silent! tabonly")

      assert.same({ tab = first, shown = tree }, seen)
    end
  )

  it("opens without a position from a recorded global that is not JSON", function()
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local file_win = vim.api.nvim_get_current_win()
    focus_terminal()

    restore_session("{here")
    Sidebar.settle()
    vim.api.nvim_set_current_win(file_win)
    Sidebar.flush()

    assert.same({ path = "mod.lua", lnum = 2 }, vim.json.decode(vim.g.ChangesetPosition).here)
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

    it("keeps the sidebar's cursor on the recorded row's file until its symbols resolve", function()
      vim.cmd.edit("other.lua")
      focus_terminal()

      restore_session({ row = { id = row_id("mod.lua", "step"), path = "mod.lua" } })
      Sidebar.await_diff()
      Sidebar.flush()

      assert.truthy(Sidebar.cursor_line():find("mod.lua", 1, true))
    end)

    it("scrolls the recorded row back into place once its file's symbols resolve", function()
      vim.cmd.edit("other.lua")
      focus_terminal()

      restore_session({ row = { id = row_id("mod.lua", "step"), path = "mod.lua", offset = 0 } })
      Sidebar.await_diff()
      answer("mod.lua", { Changes.sym("step", "Function", 0, 7, 9) })
      Sidebar.flush()

      local win = assert(window.win())
      assert.equal(vim.api.nvim_win_get_cursor(win)[1], vim.fn.line("w0", win))
    end)

    it("applies the recorded position once its file's symbols resolve", function()
      vim.cmd.edit("other.lua")
      focus_terminal()
      restore_session({
        here = { path = "mod.lua", lnum = 8 },
        row = { id = row_id("mod.lua", "step"), path = "mod.lua" },
      })
      Sidebar.await_diff()

      answer("mod.lua", { Changes.sym("step", "Function", 0, 7, 9) })
      Sidebar.flush()

      assert.truthy(Sidebar.line_with(highlights.HERE_HL):find("step", 1, true))
      assert.truthy(Sidebar.cursor_line():find("step", 1, true))
    end)
  end)
end)
