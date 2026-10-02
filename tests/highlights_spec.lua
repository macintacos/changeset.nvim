local changeset = require("changeset")
local build = require("changeset.build")
changeset.setup({ keymaps = { next = "]h", prev = "[h" } })
local render = require("changeset.render")
local window = require("changeset.window")
local Fixture = require("support.git")
local Sidebar = require("support.sidebar")

local function open_sidebar()
  changeset.open()
  Sidebar.settle()
end

describe("changeset row highlights", function()
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

  it("marks the orphan group for where you are on a line in an orphan hunk", function()
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    open_sidebar()

    assert.truthy(Sidebar.line_with(render.HERE_HL):find("Other changes", 1, true))
  end)

  it("marks the file for where you are on a line in no hunk", function()
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    open_sidebar()

    vim.cmd.wincmd("p")
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", {})

    assert.truthy(Sidebar.line_with(render.HERE_HL):find("mod.lua", 1, true))
  end)

  it("marks a folded section's header for where you are", function()
    vim.cmd.edit("mod.lua")
    open_sidebar()
    Sidebar.cursor_to("L2")
    vim.cmd.normal(vim.keycode("<CR>"))
    Sidebar.cursor_to("Implementation")
    vim.cmd.normal("h")

    vim.cmd.wincmd("p")

    assert.truthy(Sidebar.line_with(render.HERE_HL):find("Implementation", 1, true))
  end)

  it("selects the row under the sidebar's cursor while the sidebar has focus", function()
    vim.cmd.edit("mod.lua")
    open_sidebar()

    Sidebar.cursor_to("other.lua")

    assert.truthy(Sidebar.line_with(render.SELECTED_HL):find("other.lua", 1, true))
  end)

  it("drops the selected row once focus leaves the sidebar", function()
    vim.cmd.edit("mod.lua")
    open_sidebar()
    Sidebar.cursor_to("other.lua")

    vim.cmd.wincmd("p")

    assert.is_nil(Sidebar.line_with(render.SELECTED_HL))
  end)

  it("marks only the selection on the row where you also are", function()
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    open_sidebar()

    changeset.toggle()

    assert.truthy(Sidebar.line_with(render.SELECTED_HL):find("Other changes", 1, true))
    assert.is_nil(Sidebar.line_with(render.HERE_HL))
  end)

  it("marks the row opened with <CR>", function()
    vim.cmd.edit("mod.lua")
    open_sidebar()
    Sidebar.cursor_to("L8")

    vim.cmd.normal(vim.keycode("<CR>"))

    assert.truthy(Sidebar.line_with(render.PICKED_HL):find("L8", 1, true))
  end)

  it("keeps the row opened with <CR> marked through a jump to another changed file", function()
    vim.cmd.edit("mod.lua")
    open_sidebar()
    Sidebar.cursor_to("L8")
    vim.cmd.normal(vim.keycode("<CR>"))

    vim.cmd.edit("other.lua")

    assert.truthy(Sidebar.line_with(render.PICKED_HL):find("L8", 1, true))
  end)

  it("marks the row a preview showed once the cursor moves into it", function()
    vim.cmd.edit("mod.lua")
    open_sidebar()
    Sidebar.cursor_to("L8")

    vim.cmd.wincmd("p")

    assert.truthy(Sidebar.line_with(render.PICKED_HL):find("L8", 1, true))
  end)

  it("marks only where you are on the row you last opened", function()
    vim.cmd.edit("mod.lua")
    open_sidebar()
    Sidebar.cursor_to("Other changes")

    vim.cmd.normal(vim.keycode("<CR>"))

    assert.truthy(Sidebar.line_with(render.HERE_HL):find("Other changes", 1, true))
    assert.is_nil(Sidebar.line_with(render.PICKED_HL))
  end)

  it("marks only the selection on the row you last opened", function()
    vim.cmd.edit("mod.lua")
    open_sidebar()
    Sidebar.cursor_to("L8")
    vim.cmd.normal(vim.keycode("<CR>"))

    Sidebar.cursor_to("L8")

    assert.truthy(Sidebar.line_with(render.SELECTED_HL):find("L8", 1, true))
    assert.is_nil(Sidebar.line_with(render.PICKED_HL))
  end)

  it("re-resolves the row you last opened from its line when a rebuild drops it", function()
    vim.cmd.edit("mod.lua")
    open_sidebar()
    Sidebar.cursor_to("L8")
    vim.cmd.normal(vim.keycode("<CR>"))
    vim.cmd.edit("other.lua")

    vim.fn.writefile(Fixture.numbered(10, { [2] = true }), "mod.lua")
    vim.cmd("silent! checktime")
    build.refresh()
    vim.wait(5000, function()
      return not Sidebar.text():find("L8", 1, true)
    end, 25)

    assert.truthy(Sidebar.line_with(render.PICKED_HL):find("mod.lua", 1, true))
  end)

  it("clears where you are in a file outside the changeset", function()
    vim.cmd.edit("mod.lua")
    open_sidebar()
    Sidebar.cursor_to("L2")
    vim.cmd.normal(vim.keycode("<CR>"))

    vim.cmd.edit("plain.lua")

    assert.is_nil(Sidebar.line_with(render.HERE_HL))
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
    assert.truthy(Sidebar.line_with(render.HERE_HL):find("mod.lua", 1, true))
  end)

  it("keeps tracking where you are while the sidebar is closed", function()
    vim.cmd.edit("mod.lua")
    assert.is_true(build.build())

    vim.cmd.edit("other.lua")

    ---Where you are, as the session records it.
    ---@return changeset.Spot?
    local function recorded_here()
      return vim.g.ChangesetPosition and vim.json.decode(vim.g.ChangesetPosition).here
    end
    vim.wait(200, function()
      return (recorded_here() or {}).path == "other.lua"
    end, 10)
    assert.same({ path = "other.lua", lnum = 1 }, recorded_here())
  end)

  it("does not count a deleted file's notice as being in that file", function()
    Fixture.git({ "rm", "-q", "other.lua" }, tmp)
    Fixture.commit("drop other", tmp)
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    open_sidebar()
    Sidebar.cursor_to("other.lua")

    vim.cmd.wincmd("p")

    assert.is_nil(Sidebar.line_with(render.HERE_HL))
  end)
end)
