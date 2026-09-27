local changeset = require("plugins.changeset")
local render = require("plugins.changeset.render")
local window = require("plugins.changeset.window")
local Fixture = require("support.git")

local ns = assert(vim.api.nvim_get_namespaces()["changeset.rows"], "changeset.rows namespace missing")

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
---beside a `plain.lua` it leaves alone. No server answers in the specs, so every
---hunk is an orphan: `mod.lua` → "Other changes" → L2, L8.
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

---@param buf integer
---@return string[]
local function lines_of(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function open_sidebar()
  changeset.open()
  local settled = vim.wait(10000, function()
    local buf = window.buf()
    local text = buf and table.concat(lines_of(buf), "\n") or ""
    return text:find("other.lua", 1, true) ~= nil and not text:find("reading symbols", 1, true)
  end, 25)
  assert(settled, "the sidebar never settled")
end

---The one sidebar line wearing `hl`, once the scheduled tracking has run.
---@param hl string
---@return string?
local function line_with(hl)
  local flushed = false
  vim.schedule(function()
    flushed = true
  end)
  vim.wait(1000, function()
    return flushed
  end)
  local found = {}
  local buf = assert(window.buf())
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if mark[4].hl_group == hl then
      table.insert(found, lines_of(buf)[mark[2] + 1])
    end
  end
  assert(#found <= 1, ("%d lines wear %s"):format(#found, hl))
  return found[1]
end

---Put the sidebar's cursor on the first line containing `text`, as `j`/`k` would.
---@param text string
local function sidebar_cursor_to(text)
  local win = assert(window.win())
  vim.api.nvim_set_current_win(win)
  local buf = assert(window.buf())
  for i, line in ipairs(lines_of(buf)) do
    if line:find(text, 1, true) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = window.buf() })
      return
    end
  end
  error("no sidebar line contains " .. text)
end

describe("changeset row highlights", function()
  local tmp, previous_dir

  -- The tree resolves its repo from the current buffer, which falls back to the
  -- process cwd, and the fixture writes relative paths, so it has to be entered.
  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    previous_dir = vim.fn.chdir(tmp)
    assert(previous_dir ~= "", "could not enter the fixture directory")
    init_feature_repo(tmp)
  end)

  after_each(function()
    changeset.close()
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
  end)

  it("marks where you are: the orphan group for a line in an orphan hunk, else the file", function()
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    open_sidebar()

    assert.truthy(line_with(render.HERE_HL):find("Other changes", 1, true))

    vim.cmd.wincmd("p")
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", {})

    assert.truthy(line_with(render.HERE_HL):find("mod.lua", 1, true))
  end)

  it("marks a folded section's header for where you are", function()
    vim.cmd.edit("mod.lua")
    open_sidebar()
    sidebar_cursor_to("L2")
    vim.cmd.normal(vim.keycode("<CR>"))
    sidebar_cursor_to("Implementation")
    vim.cmd.normal("h")

    vim.cmd.wincmd("p")

    assert.truthy(line_with(render.HERE_HL):find("Implementation", 1, true))
  end)

  it("selects the row under the sidebar's cursor while the sidebar has focus", function()
    vim.cmd.edit("mod.lua")
    open_sidebar()

    sidebar_cursor_to("other.lua")

    assert.truthy(line_with(render.SELECTED_HL):find("other.lua", 1, true))
  end)

  it("drops the selected row once focus leaves the sidebar", function()
    vim.cmd.edit("mod.lua")
    open_sidebar()
    sidebar_cursor_to("other.lua")

    vim.cmd.wincmd("p")

    assert.is_nil(line_with(render.SELECTED_HL))
  end)

  it("marks only the selection on the row where you also are", function()
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    open_sidebar()

    changeset.toggle()

    assert.truthy(line_with(render.SELECTED_HL):find("Other changes", 1, true))
    assert.is_nil(line_with(render.HERE_HL))
  end)

  it("marks the row opened with <CR>, and keeps it through a jump to another changed file", function()
    vim.cmd.edit("mod.lua")
    open_sidebar()
    sidebar_cursor_to("L8")

    vim.cmd.normal(vim.keycode("<CR>"))
    assert.truthy(line_with(render.PICKED_HL):find("L8", 1, true))

    vim.cmd.edit("other.lua")

    assert.truthy(line_with(render.PICKED_HL):find("L8", 1, true))
  end)

  it("marks the row a preview showed once the cursor moves into it", function()
    vim.cmd.edit("mod.lua")
    open_sidebar()
    sidebar_cursor_to("L8")

    vim.cmd.wincmd("p")

    assert.truthy(line_with(render.PICKED_HL):find("L8", 1, true))
  end)

  it("marks only where you are on the row you last opened", function()
    vim.cmd.edit("mod.lua")
    open_sidebar()
    sidebar_cursor_to("Other changes")

    vim.cmd.normal(vim.keycode("<CR>"))

    assert.truthy(line_with(render.HERE_HL):find("Other changes", 1, true))
    assert.is_nil(line_with(render.PICKED_HL))
  end)

  it("marks only the selection on the row you last opened", function()
    vim.cmd.edit("mod.lua")
    open_sidebar()
    sidebar_cursor_to("L8")
    vim.cmd.normal(vim.keycode("<CR>"))

    sidebar_cursor_to("L8")

    assert.truthy(line_with(render.SELECTED_HL):find("L8", 1, true))
    assert.is_nil(line_with(render.PICKED_HL))
  end)

  it("re-resolves the row you last opened from its line when a rebuild drops it", function()
    vim.cmd.edit("mod.lua")
    open_sidebar()
    sidebar_cursor_to("L8")
    vim.cmd.normal(vim.keycode("<CR>"))
    vim.cmd.edit("other.lua")

    vim.fn.writefile(numbered(10, { [2] = true }), "mod.lua")
    vim.cmd("silent! checktime")
    changeset.refresh()
    vim.wait(5000, function()
      local buf = assert(window.buf())
      return not table.concat(lines_of(buf), "\n"):find("L8", 1, true)
    end, 25)

    assert.truthy(line_with(render.PICKED_HL):find("mod.lua", 1, true))
  end)

  it("clears where you are in a file outside the changeset", function()
    vim.cmd.edit("mod.lua")
    open_sidebar()
    sidebar_cursor_to("L2")
    vim.cmd.normal(vim.keycode("<CR>"))

    vim.cmd.edit("plain.lua")

    assert.is_nil(line_with(render.HERE_HL))
  end)

  it("leaves where you are alone while the sidebar previews another file", function()
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    open_sidebar()
    local win = assert(window.win())
    vim.api.nvim_set_current_win(win)

    for _ = 1, 4 do
      vim.cmd.normal("]h")
    end
    -- The main loop's, which `:normal` does not fire.
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = window.buf() })

    assert.truthy(vim.api.nvim_get_current_line():find("other.lua", 1, true))
    assert.truthy(line_with(render.HERE_HL):find("mod.lua", 1, true))
  end)

  it("keeps tracking where you are while the sidebar is closed", function()
    vim.cmd.edit("mod.lua")
    assert.is_true(changeset.build())

    vim.cmd.edit("other.lua")

    vim.wait(200, function()
      return (changeset._tree().here or {}).path == "other.lua"
    end, 10)
    assert.same({ path = "other.lua", lnum = 1 }, changeset._tree().here)
  end)

  it("does not count a deleted file's notice as being in that file", function()
    Fixture.git({ "rm", "-q", "other.lua" }, tmp)
    Fixture.commit("drop other", tmp)
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    open_sidebar()
    sidebar_cursor_to("other.lua")

    vim.cmd.wincmd("p")

    assert.is_nil(line_with(render.HERE_HL))
  end)
end)
