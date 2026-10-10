local build = require("changeset.build")
local changeset = require("changeset")
local comment_store = require("changeset.comment_store")
local window = require("changeset.window")
local CommentWindow = require("support.comment_window")
local Dialog = require("support.dialog")
local Fixture = require("support.git")
local Notify = require("support.notify")
local Sidebar = require("support.sidebar")
local present = require("support.present")

describe("a review comment on a whole file", function()
  local tmp ---@type string
  local previous_dir ---@type string

  before_each(function()
    if not vim.g.loaded_changeset then
      vim.cmd("runtime plugin/changeset.lua")
    end
    tmp, previous_dir = Fixture.enter_tempdir()
    Fixture.init_repo("trunk", tmp)
    vim.fn.writefile({ "local M = {}", "return M" }, "other.lua")
    vim.fn.writefile({ "return 1" }, "gone.lua")
    Fixture.commit("base", tmp)
    Fixture.git({ "checkout", "-q", "-b", "feature" }, tmp)
    vim.fn.writefile({ "alpha 1", "alpha 2", "alpha 3" }, "alpha.txt")
    vim.fn.writefile({ "local M = {}", "M.x = 1", "return M" }, "other.lua")
    os.remove("gone.lua")
    Fixture.commit("feature", tmp)
    os.remove(comment_store.path())
  end)

  after_each(function()
    vim.cmd("silent! fclose!")
    vim.cmd.stopinsert()
    changeset.close()
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
    os.remove(comment_store.path())
  end)

  ---Keeps `comments`, then opens the sidebar on alpha.txt once its tree has settled.
  ---@param comments changeset.ReviewComment[]?
  ---@return string root
  local function open_sidebar(comments)
    vim.cmd.edit("alpha.txt")
    local root = require("changeset.paths").root(0)
    for _, comment in ipairs(comments or {}) do
      comment_store.keep(root, comment)
    end
    changeset.open()
    assert.is_true(vim.wait(10000, function()
      local tree = build.current()
      return tree ~= nil and tree.collected
    end, 25))
    Sidebar.settle()
    return root
  end

  ---The sidebar lines containing `text`, top first.
  ---@param text string
  ---@return integer[]
  local function lines_of(text)
    local found = {}
    for i, line in ipairs(Sidebar.lines()) do
      if line:find(text, 1, true) then
        found[#found + 1] = i
      end
    end
    return found
  end

  ---Puts the sidebar's cursor on its last line containing `text`, under Comments' rows.
  ---@param text string
  ---@return integer lnum
  local function cursor_to_last(text)
    local lnum = present(lines_of(text)[#lines_of(text)], "no sidebar line contains " .. text)
    local win = present(window.win())
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(0, { lnum, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = window.buf() })
    return lnum
  end

  ---Presses the first save key in the window, as typed in insert mode.
  ---@param win integer
  local function save(win)
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_feedkeys(vim.keycode("a<C-s>"), "x", false)
  end

  it("is written from a deleted file's row, in a window under that row", function()
    local root = open_sidebar()
    local lnum = cursor_to_last("gone.lua")

    vim.cmd("Changeset comment new")

    local win = present(CommentWindow.win())
    local config = vim.api.nvim_win_get_config(win)
    assert.equal(window.win(), config.win)
    assert.same({ lnum - 1, 0 }, config.bufpos)
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(win), 0, -1, false, { "why drop it?" })
    save(win)
    assert.same({ { path = "gone.lua", body = "why drop it?" } }, comment_store.list(root))
  end)

  it("is listed under Comments by its file's name alone, ahead of its lines' comments", function()
    open_sidebar({ { path = "alpha.txt", line = 2, body = "a line" }, { path = "alpha.txt", body = "the file" } })

    local file = present(lines_of("the file")[1])
    assert.equal(2, file)
    assert.equal(file + 1, lines_of("alpha.txt:2")[1])
  end)

  it("opens to edit under its Comments row on <CR>, holding its text", function()
    open_sidebar({ { path = "gone.lua", body = "why drop it?" } })
    local lnum = cursor_to_last("why drop it?")

    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)

    local win = present(CommentWindow.win())
    local config = vim.api.nvim_win_get_config(win)
    assert.equal(window.win(), config.win)
    assert.same({ lnum - 1, 0 }, config.bufpos)
    assert.equal("why drop it?", CommentWindow.text(win))
  end)

  it("previews its deleted file's notice from its Comments row", function()
    open_sidebar({ { path = "gone.lua", body = "why drop it?" } })

    cursor_to_last("why drop it?")

    local previewed = vim.api.nvim_win_get_buf(vim.fn.win_getid(vim.fn.winnr("#")))
    assert.truthy((table.concat(vim.api.nvim_buf_get_lines(previewed, 0, -1, false)):find("deleted", 1, true)))
  end)

  it("is passed over by a step, having no line to open", function()
    open_sidebar({ { path = "gone.lua", body = "why drop it?" } })
    local notes, restore = Notify.capture()

    local ok, err = pcall(changeset.step, -10)

    restore()
    assert.is_true(ok, tostring(err))
    assert.same({}, Notify.messages(notes, vim.log.levels.WARN))
    assert.is_nil((Sidebar.cursor_line():find("why drop it?", 1, true)))
  end)

  it("is deleted by :Changeset comment del on its file's row", function()
    local root = open_sidebar({ { path = "gone.lua", body = "why drop it?" } })
    cursor_to_last("gone.lua")

    vim.cmd("Changeset comment del")

    assert.same({}, comment_store.list(root))
  end)

  it("asks before :Changeset comment del deletes it from its window, from outside the repository", function()
    local root = open_sidebar({ { path = "gone.lua", body = "why drop it?" } })
    cursor_to_last("gone.lua")
    vim.cmd("Changeset comment new")
    assert.not_nil(CommentWindow.win())
    -- The window's buffer names no file, so only the sidebar's tree can say which repository it is in.
    local elsewhere = vim.fn.tempname()
    vim.fn.mkdir(elsewhere, "p")
    vim.fn.chdir(elsewhere)

    vim.cmd("Changeset comment del")
    Dialog.press("D")

    assert.is_true(vim.wait(2000, function()
      return #comment_store.list(root) == 0
    end, 10))
    vim.fn.delete(elsewhere, "rf")
  end)

  it("is kept as a draft when another subcommand runs from its window, which runs from its row", function()
    local root = open_sidebar()
    cursor_to_last("gone.lua")
    vim.cmd("Changeset comment new")
    local win = present(CommentWindow.win())
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(win), 0, -1, false, { "unsure" })

    vim.cmd("Changeset comment list")

    assert.is_true(vim.wait(2000, function()
      return vim.fn.getqflist({ size = 0 }).size == 1
    end, 10))
    assert.same({ { path = "gone.lua", body = "unsure", draft = true } }, comment_store.list(root))
    vim.cmd("cclose")
  end)
end)
