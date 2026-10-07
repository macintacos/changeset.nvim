local build = require("changeset.build")
local render = require("changeset.render")
local changeset = require("changeset")
local comment_store = require("changeset.comment_store")
local window = require("changeset.window")
local Dialog = require("support.dialog")
local Fixture = require("support.git")
local Sidebar = require("support.sidebar")

describe("the sidebar's Comments section", function()
  local tmp, previous_dir

  before_each(function()
    tmp, previous_dir = Fixture.enter_tempdir()
    Fixture.init_repo("trunk", tmp)
    vim.fn.writefile({ "local M = {}", "return M" }, "other.lua")
    Fixture.commit("other", tmp)
    Fixture.git({ "checkout", "-q", "-b", "feature" }, tmp)
    local lines = {}
    for i = 1, 40 do
      lines[i] = "alpha " .. i
    end
    vim.fn.writefile(lines, "alpha.txt")
    vim.fn.writefile({ "local M = {}", "M.x = 1", "return M" }, "other.lua")
    Fixture.commit("alpha", tmp)
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

  local COMMENTS = {
    { path = "alpha.txt", line = 13, body = "check this\nmore" },
    { path = "alpha.txt", line = 6, start_line = 5, body = "a range" },
    { path = "alpha.txt", line = 30, body = "why x" },
  }

  ---Keeps `COMMENTS` and opens the sidebar on alpha.txt.
  ---@return string root
  local function open_with_review_comments()
    vim.cmd.edit("alpha.txt")
    local root = require("changeset.paths").root(0)
    for _, comment in ipairs(COMMENTS) do
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

  ---The first sidebar line containing `text`.
  ---@param text string
  ---@return integer?
  local function line_of(text)
    for i, line in ipairs(Sidebar.lines()) do
      if line:find(text, 1, true) then
        return i
      end
    end
  end

  it("lists the review comments in a section above Implementation", function()
    open_with_review_comments()

    local comments, implementation = line_of("Comments"), line_of("Implementation")
    assert.equal(1, comments)
    assert.truthy(Sidebar.lines()[1]:find("3 comments", 1, true))
    assert.equal(comments + 1, line_of("alpha.txt:5-6  a range"))
    assert.equal(comments + 2, line_of("alpha.txt:13  check this"))
    assert.is_true(implementation > line_of("alpha.txt:30"))
  end)

  it("follows a dropped comment without rebuilding the tree", function()
    local root = open_with_review_comments()
    local refreshed = 0
    local refresh = build.refresh
    build.refresh = function()
      refreshed = refreshed + 1
    end

    comment_store.drop(root, COMMENTS[2])

    build.refresh = refresh
    assert.is_nil(line_of("a range"))
    assert.truthy(Sidebar.lines()[1]:find("2 comments", 1, true))
    assert.equal(0, refreshed)
  end)

  it("is left out while there is nothing to list", function()
    vim.cmd.edit("alpha.txt")
    changeset.open()
    assert.is_true(vim.wait(10000, function()
      local tree = build.current()
      return tree ~= nil and tree.collected
    end, 25))
    Sidebar.settle()

    assert.is_nil(line_of("Comments"))
    assert.truthy(Sidebar.lines()[1]:find("Implementation", 1, true))
  end)

  it("previews a comment row's line", function()
    open_with_review_comments()

    Sidebar.cursor_to("alpha.txt:13")

    local previewed = vim.fn.win_getid(vim.fn.winnr("#"))
    assert.equal("alpha.txt", vim.fs.basename(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(previewed))))
    assert.equal(13, vim.api.nvim_win_get_cursor(previewed)[1])
  end)

  it("folds from its header, and steps to the next section", function()
    open_with_review_comments()
    local win = assert(window.win())
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { 1, 0 })

    vim.cmd.normal("h")
    assert.truthy(Sidebar.lines()[2]:find("Implementation", 1, true))

    vim.cmd.normal("]]")
    assert.truthy(Sidebar.cursor_line():find("Implementation", 1, true))
  end)

  it("counts no comment row as a file in the footer", function()
    open_with_review_comments()

    Sidebar.cursor_to("alpha.txt:13")

    assert.is_nil(changeset.footer():find("file %d"))
  end)

  ---The review comment window, once one is open.
  ---@return integer? win
  local function comment_window()
    local win
    vim.wait(2000, function()
      win = vim.iter(vim.api.nvim_list_wins()):find(function(w)
        return vim.api.nvim_win_get_config(w).relative == "win"
      end)
      return win ~= nil
    end, 10)
    return win
  end

  ---@param win integer
  ---@return string
  local function text_of(win)
    return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
  end

  ---Presses `key` in the sidebar with its cursor on the first line containing `text`.
  ---@param text string
  ---@param key string
  local function press_on(text, key)
    Sidebar.cursor_to(text)
    vim.api.nvim_feedkeys(vim.keycode(key), "x", false)
  end

  ---Presses the first save key in the window, as typed in insert mode.
  ---@param win integer
  local function save(win)
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_feedkeys(vim.keycode("a<C-s>"), "x", false)
  end

  it("opens a review comment's window on its line, holding its text, with <CR>", function()
    open_with_review_comments()

    press_on("alpha.txt:13", "<CR>")

    local win = assert(comment_window())
    local config = vim.api.nvim_win_get_config(win)
    assert.equal("check this\nmore", text_of(win))
    assert.same({ 12, 0 }, config.bufpos)
    assert.equal("alpha.txt", vim.fs.basename(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(config.win))))
  end)

  it("opens a range's window, holding its text, after a split's jump", function()
    open_with_review_comments()
    local before = #vim.api.nvim_tabpage_list_wins(0)

    press_on("alpha.txt:5-6", "<C-x>")

    local win = assert(comment_window())
    assert.equal("a range", text_of(win))
    assert.equal(before + 2, #vim.api.nvim_tabpage_list_wins(0))
  end)

  it("opens a review comment's window once <S-CR> has closed the sidebar", function()
    open_with_review_comments()

    press_on("alpha.txt:13", "<S-CR>")

    local win = assert(comment_window())
    assert.is_nil(window.win())
    assert.equal(win, vim.api.nvim_get_current_win())
  end)

  it("marks the comment row it opened as the pick", function()
    open_with_review_comments()

    press_on("alpha.txt:13", "<CR>")

    assert.truthy(Sidebar.line_with(render.PICKED_HL):find("alpha.txt:13", 1, true))
  end)

  it("replaces the review comment's text when its window saves", function()
    local root = open_with_review_comments()
    press_on("alpha.txt:13", "<CR>")
    local win = assert(comment_window())
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(win), 0, -1, false, { "update: after", "second line" })

    save(win)

    assert.equal(
      "update: after\nsecond line",
      require("changeset.review_comments").at(comment_store.list(root), "alpha.txt", 13).body
    )
  end)

  it("asks to delete the review comment when its window saves blank", function()
    local root = open_with_review_comments()
    press_on("alpha.txt:13", "<CR>")
    local win = assert(comment_window())
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(win), 0, -1, false, { "" })

    save(win)

    assert.truthy(Dialog.lines()[2]:find("alpha.txt:13", 1, true))
    assert.equal(3, #comment_store.list(root))
  end)

  it("asks, then deletes the review comment on a row with d", function()
    local root = open_with_review_comments()

    press_on("alpha.txt:13", "d")
    assert.truthy(Dialog.lines()[2]:find("alpha.txt:13", 1, true))
    Dialog.press("D")

    assert.is_true(vim.wait(5000, function()
      return #comment_store.list(root) == 2
    end, 25))
    assert.truthy(Sidebar.lines()[1]:find("2 comments", 1, true))
  end)

  it("stops at the question on dd, deleting nothing until asked", function()
    local root = open_with_review_comments()

    press_on("alpha.txt:13", "dd")

    assert.truthy(Dialog.lines()[2]:find("alpha.txt:13", 1, true))
    assert.equal(3, #comment_store.list(root))
  end)

  it("deletes nothing with d on a row that lists no comment", function()
    open_with_review_comments()

    press_on("other.lua", "d")

    assert.same(
      {},
      vim.tbl_filter(function(win)
        return vim.api.nvim_win_get_config(win).relative ~= ""
      end, vim.api.nvim_list_wins())
    )
  end)
end)
