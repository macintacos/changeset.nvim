local changeset = require("plugins.changeset")
local window = require("plugins.changeset.window")
local Fixture = require("support.git")

---@param count integer
---@param changed table<integer, true>? Lines to rewrite.
---@return string[]
local function numbered(count, changed)
  local lines = {}
  for i = 1, count do
    lines[i] = (changed or {})[i] and ("changed " .. i) or ("line " .. i)
  end
  return lines
end

---A `feature` branch changing lines 2 and 8 of `mod.lua` and the last of `other.lua`,
---beside a `plain.lua` it leaves alone. Unless a spec stubs `resolve.start`, no server
---answers, so every hunk is an orphan: `mod.lua` → "Other changes" → L2, L8.
---@param cwd string
local function init_feature_repo(cwd)
  Fixture.init_repo("trunk", cwd)
  vim.fn.writefile(numbered(10), "mod.lua")
  vim.fn.writefile({ "local a = 1", "", "return 1" }, "other.lua")
  vim.fn.writefile({ "return 0" }, "plain.lua")
  Fixture.commit("base", cwd)

  Fixture.git({ "checkout", "-q", "-b", "feature" }, cwd)
  vim.fn.writefile(numbered(10, { [2] = true, [8] = true }), "mod.lua")
  vim.fn.writefile({ "local a = 1", "", "return 2" }, "other.lua")
  Fixture.commit("change", cwd)
end

---@return string[]
local function sidebar_lines()
  return vim.api.nvim_buf_get_lines(assert(window.buf()), 0, -1, false)
end

---Wait for the tree to hold both files with every file's symbols read.
local function settle()
  local settled = vim.wait(10000, function()
    local text = window.buf() and table.concat(sidebar_lines(), "\n") or ""
    return text:find("other.lua", 1, true) and not text:find("reading symbols", 1, true)
  end, 25)
  assert(settled, "the sidebar never settled")
end

---Let the scheduled tracking run.
local function flush()
  local flushed = false
  vim.schedule(function()
    flushed = true
  end)
  vim.wait(1000, function()
    return flushed
  end)
end

---Put the sidebar's cursor on the first line containing `text`, as `j`/`k` would.
---@param text string
local function sidebar_cursor_to(text)
  vim.api.nvim_set_current_win(window.win())
  for i, line in ipairs(sidebar_lines()) do
    if line:find(text, 1, true) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = window.buf() })
      return
    end
  end
  error("no sidebar line contains " .. text)
end

local function focus_terminal()
  vim.cmd("new")
  vim.cmd.terminal()
end

---The text of the line the sidebar's cursor is on.
---@return string
local function sidebar_cursor_line()
  local win = assert(window.win())
  return sidebar_lines()[vim.api.nvim_win_get_cursor(win)[1]]
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
  -- process cwd, and the fixture writes relative paths, so it has to be entered.
  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    previous_dir = vim.fn.chdir(tmp)
    assert(previous_dir ~= "", "could not enter the fixture directory")
    init_feature_repo(tmp)
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
    settle()

    focus_terminal()
    flush()

    assert.same({ path = "mod.lua", lnum = 8 }, changeset._tree().here)
  end)

  it("records where you are and the sidebar's cursor row in a session global", function()
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    changeset.open()
    settle()

    sidebar_cursor_to("other.lua")
    flush()

    assert.same(
      { here = { path = "mod.lua", lnum = 8 }, row = { id = "other.lua", path = "other.lua" } },
      vim.json.decode(vim.g.ChangesetPosition)
    )
  end)

  it("restores where you were and the sidebar's cursor row with focus in a terminal", function()
    vim.cmd.edit("mod.lua")
    focus_terminal()

    restore_session({ here = { path = "mod.lua", lnum = 8 }, row = { id = "other.lua", path = "other.lua" } })
    settle()
    flush()

    assert.same({ path = "mod.lua", lnum = 8 }, changeset._tree().here)
    assert.truthy(sidebar_cursor_line():find("other.lua", 1, true))
  end)

  it("carries the recorded position through :mksession", function()
    local sessionoptions = vim.o.sessionoptions
    vim.o.sessionoptions = "blank,buffers,curdir,winsize,globals,terminal"
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    changeset.open()
    settle()
    sidebar_cursor_to("L2")
    focus_terminal()
    flush()
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

    restore_session({ here = { path = "gone.lua", lnum = 3 }, row = { id = "other.lua\0gone", path = "other.lua" } })
    settle()
    flush()

    assert.is_nil(changeset._tree().restoring)
    assert.is_nil(changeset._tree().here)
    vim.api.nvim_set_current_win(file_win)
    flush()
    assert.same({ path = "mod.lua", lnum = 2 }, vim.json.decode(vim.g.ChangesetPosition).here)
  end)

  it("settles a recorded row on a file the branch deletes, then follows you again", function()
    Fixture.git({ "rm", "-q", "plain.lua" }, tmp)
    Fixture.commit("delete", tmp)
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local file_win = vim.api.nvim_get_current_win()
    focus_terminal()

    restore_session({ row = { id = "plain.lua", path = "plain.lua" } })
    settle()
    flush()

    assert.is_nil(changeset._tree().restoring)
    assert.truthy(sidebar_cursor_line():find("plain.lua", 1, true))
    vim.api.nvim_set_current_win(file_win)
    flush()
    assert.same({ path = "mod.lua", lnum = 2 }, vim.json.decode(vim.g.ChangesetPosition).here)
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
      settle()

      assert.is_nil(changeset._tree().restoring)
      assert.is_nil(changeset._tree().here)
    end)
  end

  describe("while symbols are still being read", function()
    local resolve = require("plugins.changeset.resolve")
    local real_start = resolve.start
    ---@type fun(path: string, items: table[]?)
    local answer

    ---A function spanning `first`..`last` of `mod.lua`, as a server would report it.
    local function symbol(name, first, last)
      return {
        name = name,
        text = name,
        kind = "Function",
        path = "mod.lua",
        lnum = first,
        col = 1,
        end_lnum = first,
        end_col = #name + 1,
        depth = 0,
        guides = "",
        range_lnum = first,
        range_end_lnum = last,
      }
    end

    local function diff_arrived()
      assert(
        vim.wait(10000, function()
          return window.buf() and table.concat(sidebar_lines(), "\n"):find("other.lua", 1, true)
        end, 25),
        "the diff never arrived"
      )
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
      restore_session({ here = { path = "mod.lua", lnum = 8 }, row = { id = "mod.lua\0step", path = "mod.lua" } })
      diff_arrived()

      answer("mod.lua", { symbol("step", 7, 9) })
      flush()

      assert.same({ path = "mod.lua", lnum = 8 }, changeset._tree().here)
      assert.truthy(sidebar_cursor_line():find("step", 1, true))
    end)

    it("lets a file you move into before the build finishes win over the recorded one", function()
      vim.cmd.edit("other.lua")
      local file_win = vim.api.nvim_get_current_win()
      focus_terminal()
      restore_session({ here = { path = "mod.lua", lnum = 8 } })
      diff_arrived()

      vim.api.nvim_set_current_win(file_win)
      flush()
      answer("mod.lua", { symbol("step", 7, 9) })

      assert.same({ path = "other.lua", lnum = 1 }, changeset._tree().here)
    end)

    it("lets a row you move to in a focused sidebar win over the recorded one", function()
      restore_session({ row = { id = "mod.lua", path = "mod.lua" } }, true)
      diff_arrived()

      sidebar_cursor_to("other.lua")
      answer("mod.lua", {})

      assert.truthy(sidebar_cursor_line():find("other.lua", 1, true))
    end)
  end)
end)
