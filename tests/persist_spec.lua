local changeset = require("changeset")
local render = require("changeset.render")
local tree = require("changeset.tree")
local window = require("changeset.window")
local Fixture = require("support.git")
local Cursor = require("support.cursor")
local Sidebar = require("support.sidebar")

local function focus_terminal()
  vim.cmd("new")
  vim.cmd.terminal()
end

---The id of the Implementation row for `path`, or for the symbol chain under it.
---@param path string
---@param ... string Symbol names, outermost first.
---@return string
local function row_id(path, ...)
  return table.concat({ tree.section_id("implementation"), path, ... }, "\0")
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

    assert.same({ path = "mod.lua", lnum = 8 }, changeset._tree().here)
  end)

  it("keeps where you are while focus sits in a help window", function()
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    changeset.open()
    Sidebar.settle()

    vim.cmd.help("help")
    Sidebar.flush()

    assert.same({ path = "mod.lua", lnum = 8 }, changeset._tree().here)
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

    assert.same({ path = "mod.lua", lnum = 8 }, changeset._tree().here)
    assert.truthy(Sidebar.cursor_line():find("other.lua", 1, true))
  end)

  it("restores where you were and the sidebar's cursor row with focus in a terminal", function()
    vim.cmd.edit("mod.lua")
    focus_terminal()

    restore_session({
      here = { path = "mod.lua", lnum = 8 },
      row = { id = row_id("other.lua"), path = "other.lua" },
    })
    Sidebar.settle()
    Sidebar.flush()

    assert.same({ path = "mod.lua", lnum = 8 }, changeset._tree().here)
    assert.truthy(Sidebar.cursor_line():find("other.lua", 1, true))
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

  it("ignores a recorded file and row the changeset no longer holds", function()
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local file_win = vim.api.nvim_get_current_win()
    focus_terminal()

    restore_session({
      here = { path = "gone.lua", lnum = 3 },
      row = { id = row_id("other.lua", "gone"), path = "other.lua" },
    })
    Sidebar.settle()
    Sidebar.flush()

    assert.is_nil(changeset._tree().restoring)
    assert.is_nil(changeset._tree().here)
    vim.api.nvim_set_current_win(file_win)
    Sidebar.flush()
    assert.same({ path = "mod.lua", lnum = 2 }, vim.json.decode(vim.g.ChangesetPosition).here)
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

    assert.is_nil(changeset._tree().restoring)
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
    local notify = vim.notify
    vim.notify = function() end

    local ok, err = pcall(restore_session, { here = { path = "mod.lua", lnum = 8 } })
    vim.notify = notify
    vim.fn.chdir(tmp)
    vim.fn.delete(outside, "rf")
    assert(ok, err)
    assert.equal(before, #vim.api.nvim_tabpage_list_wins(0))
  end)

  for name, value in pairs({
    ["not JSON"] = "{here",
    ["null"] = "null",
    ["wrong types"] = vim.json.encode({ here = { path = 1, lnum = "8" }, row = { id = 2, path = {} } }),
  }) do
    it("opens without a position from a recorded global that is " .. name, function()
      vim.cmd.edit("mod.lua")
      focus_terminal()

      restore_session(value)
      Sidebar.settle()

      assert.is_nil(changeset._tree().restoring)
      assert.is_nil(changeset._tree().here)
    end)
  end

  describe("while symbols are still being read", function()
    local resolve = require("changeset.resolve")
    local real_start = resolve.start
    ---@type fun(path: string, items: table[]?)
    local answer

    ---A symbol spanning `first`..`last` (a top-level function unless told otherwise).
    ---@param name string
    ---@param first integer
    ---@param last integer
    ---@param opts { kind: string?, depth: integer? }?
    local function symbol(name, first, last, opts)
      opts = opts or {}
      return {
        name = name,
        kind = opts.kind or "Function",
        lnum = first,
        depth = opts.depth or 0,
        range_lnum = first,
        range_end_lnum = last,
      }
    end

    before_each(function()
      resolve.start = function(_, _, on_file)
        answer = on_file
        return function() end
      end
    end)

    after_each(function()
      resolve.start = real_start
    end)

    it("applies the recorded position once its file's symbols resolve", function()
      vim.cmd.edit("other.lua")
      focus_terminal()
      restore_session({
        here = { path = "mod.lua", lnum = 8 },
        row = { id = row_id("mod.lua", "step"), path = "mod.lua" },
      })
      Sidebar.await_diff()

      answer("mod.lua", { symbol("step", 7, 9) })
      Sidebar.flush()

      assert.same({ path = "mod.lua", lnum = 8 }, changeset._tree().here)
      assert.truthy(Sidebar.cursor_line():find("step", 1, true))
    end)

    it("lets a file you move into before the build finishes win over the recorded one", function()
      vim.cmd.edit("other.lua")
      local file_win = vim.api.nvim_get_current_win()
      focus_terminal()
      restore_session({ here = { path = "mod.lua", lnum = 8 } })
      Sidebar.await_diff()

      vim.api.nvim_set_current_win(file_win)
      Sidebar.flush()
      answer("mod.lua", { symbol("step", 7, 9) })

      assert.same({ path = "other.lua", lnum = 1 }, changeset._tree().here)
    end)

    it("lets a row you move to in a focused sidebar win over the recorded one", function()
      restore_session({ row = { id = row_id("mod.lua", "step"), path = "mod.lua" } }, true)
      Sidebar.await_diff()

      Sidebar.cursor_to("other.lua")
      answer("mod.lua", { symbol("step", 7, 9) })
      Sidebar.flush()

      assert.truthy(Sidebar.cursor_line():find("other.lua", 1, true))
    end)

    it("lets entering the sidebar before the build finishes win over the recorded row", function()
      vim.cmd.edit("plain.lua")
      restore_session({ row = { id = row_id("mod.lua", "step"), path = "mod.lua" } })
      Sidebar.await_diff()

      window.focus()
      answer("mod.lua", { symbol("step", 7, 9) })
      Sidebar.flush()

      assert.truthy(Sidebar.cursor_line():find("Implementation", 1, true))
    end)

    it("restores a split file's row onto its own copy and paints you there on the Tests copy", function()
      vim.fn.mkdir("src", "p")
      vim.fn.writefile({ "fn load() {}", "", "mod tests {", "    fn refreshes() {", "    }", "}" }, "src/session.rs")
      Fixture.commit("rust", tmp)
      vim.cmd.edit("other.lua")
      focus_terminal()
      restore_session({
        here = { path = "src/session.rs", lnum = 4 },
        row = { id = row_id("src/session.rs"), path = "src/session.rs" },
      })
      Sidebar.await_diff()

      answer("mod.lua", {})
      answer("other.lua", {})
      answer("src/session.rs", {
        symbol("load", 1, 1),
        symbol("tests", 3, 6, { kind = "Module" }),
        symbol("refreshes", 4, 5, { depth = 1 }),
      })
      Sidebar.flush()

      local lines = Sidebar.lines()
      local cursor = vim.api.nvim_win_get_cursor((assert(window.win())))[1]
      local tests = assert(vim.iter(ipairs(lines)):find(function(_, line)
        return line:find("Tests", 1, true) ~= nil
      end))
      assert.truthy(lines[cursor]:find("session.rs", 1, true))
      assert.truthy(cursor < tests)
      assert.truthy(Sidebar.line_with(render.HERE_HL):find("refreshes", 1, true))
    end)
  end)
end)
