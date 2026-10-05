local build = require("changeset.build")
local render = require("changeset.render")
local changeset = require("changeset")
local drafts = require("changeset.drafts")
local pending_state = require("changeset.pending_state")
local window = require("changeset.window")
local Fixture = require("support.git")
local Sidebar = require("support.sidebar")
local gh = require("support.gh")

-- A file of its own: a find still in flight from an earlier case would take the answers a
-- later one queues.
describe("the sidebar's Comments section", function()
  local tmp, previous_dir, select
  ---@type string[] Every question `vim.ui.select` was asked.
  local asked
  ---@type string? What each question is answered with; nil dismisses it.
  local choice

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
    vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "trunk", number = 1 })
    os.remove(drafts.path())
    select, asked, choice = vim.ui.select, {}, nil
    vim.ui.select = function(_, opts, on_choice)
      table.insert(asked, opts.prompt)
      on_choice(choice)
    end
  end)

  after_each(function()
    vim.ui.select = select
    vim.cmd.stopinsert()
    changeset.close()
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
    vim.env.FAKE_GH_PR = nil
    gh.reset()
  end)

  ---Opens the sidebar on alpha.txt with the sandbox's six review comments, waiting for GitHub's answer.
  ---@return changeset.pending_review.Pr pr
  local function open_with_review_comments()
    gh.fixture("find-pending-review")
    gh.fixture("review-comments-paginate-slurp")
    vim.cmd.edit("alpha.txt")
    changeset.open()
    local found
    assert.is_true(vim.wait(10000, function()
      local tree = build.current()
      found = tree and tree.pr and pending_state.get(tree.root, tree.pr)
      return found ~= nil
    end, 25))
    Sidebar.settle()
    return found.pr
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

  it("lists the review comments and drafts in a section above Implementation", function()
    local pr = open_with_review_comments()
    drafts.keep(pr, { path = "alpha.txt", line = 6, start_line = 5, head = pr.head, body = "a draft" })

    local comments, implementation = line_of("Comments"), line_of("Implementation")
    assert.equal(1, comments)
    assert.truthy(Sidebar.lines()[1]:find("7 comments", 1, true))
    assert.equal(comments + 1, line_of("File-level review comment"))
    assert.equal(comments + 2, line_of("○"))
    assert.truthy(line_of("alpha.txt:5-6  a draft"))
    assert.truthy(line_of("beta.txt:16  Added line in a second file"))
    assert.is_true(implementation > line_of("beta.txt:16"))
  end)

  it("follows a dropped draft without rebuilding the tree", function()
    local pr = open_with_review_comments()
    local draft = { path = "alpha.txt", line = 6, start_line = 5, head = pr.head, body = "a draft" }
    drafts.keep(pr, draft)
    local refreshed = 0
    local refresh = build.refresh
    build.refresh = function()
      refreshed = refreshed + 1
    end

    drafts.drop(pr, draft)

    build.refresh = refresh
    assert.is_nil(line_of("a draft"))
    assert.truthy(Sidebar.lines()[1]:find("6 comments", 1, true))
    assert.equal(0, refreshed)
  end)

  it("is left out while there is nothing to list", function()
    gh.fixture("find-pending-review-empty")
    vim.cmd.edit("alpha.txt")
    changeset.open()
    assert.is_true(vim.wait(10000, function()
      local tree = build.current()
      return tree ~= nil and tree.pr ~= nil and pending_state.get(tree.root, tree.pr) ~= nil
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
    local buf = vim.api.nvim_win_get_buf(win)
    vim
      .iter(vim.api.nvim_buf_get_keymap(buf, "i"))
      :find(function(keymap)
        return keymap.lhs == "<C-S>"
      end)
      .callback()
  end

  ---The arguments of each gh call running `mutation`.
  ---@param mutation string
  ---@return string[][]
  local function calls_to(mutation)
    return vim.tbl_filter(function(args)
      return vim.iter(args):any(function(arg)
        return arg:find(mutation, 1, true) ~= nil
      end)
    end, gh.calls())
  end

  it("opens a review comment's window on its line, holding its text, with <CR>", function()
    open_with_review_comments()

    press_on("alpha.txt:13", "<CR>")

    local win = assert(comment_window())
    local config = vim.api.nvim_win_get_config(win)
    assert.equal("Unchanged context line inside a hunk (last context line)", text_of(win))
    assert.same({ 12, 0 }, config.bufpos)
    assert.equal("alpha.txt", vim.fs.basename(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(config.win))))
  end)

  it("reopens a draft's window, holding its text, after a split's jump", function()
    local pr = open_with_review_comments()
    drafts.keep(pr, { path = "alpha.txt", line = 6, start_line = 5, head = pr.head, body = "a draft" })
    local before = #vim.api.nvim_tabpage_list_wins(0)

    press_on("alpha.txt:5-6", "-")

    local win = assert(comment_window())
    assert.equal("a draft", text_of(win))
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

  it("updates the review comment on GitHub when its window saves", function()
    open_with_review_comments()
    press_on("alpha.txt:13", "<CR>")
    local win = assert(comment_window())
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(win), 0, -1, false, { "update: after", "second line" })
    gh.fixture("update-review-comment")
    gh.fixture("find-pending-review")
    gh.fixture("review-comments-paginate-slurp")

    save(win)

    assert.is_true(vim.wait(5000, function()
      return #calls_to("updatePullRequestReviewComment") == 1
    end, 25))
    local update = calls_to("updatePullRequestReviewComment")[1]
    assert.is_true(vim.list_contains(update, "id=PRRC_kwDOU6Rmbc74w1gd"))
    assert.is_true(vim.list_contains(update, "body=update: after\nsecond line"))
  end)

  it("asks to delete the review comment when its window saves blank, sending GitHub no body", function()
    open_with_review_comments()
    press_on("alpha.txt:13", "<CR>")
    local win = assert(comment_window())
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(win), 0, -1, false, { "" })

    save(win)

    assert.is_true(vim.wait(5000, function()
      return #asked > 0
    end, 25))
    assert.same({ "Delete the review comment on line 13 of alpha.txt?" }, asked)
    assert.same({}, calls_to("updatePullRequestReviewComment"))
  end)

  it("asks, then deletes the review comment on a row with d", function()
    open_with_review_comments()
    choice = "Yes"
    gh.fixture("find-pending-review")
    gh.fixture("review-comments-paginate-slurp")
    gh.fixture("delete-review-comment")
    gh.fixture("find-pending-review")
    gh.fixture("review-comments-after-delete")

    press_on("alpha.txt:13", "d")

    assert.same({ "Delete the review comment on line 13 of alpha.txt?" }, asked)
    assert.is_true(vim.wait(5000, function()
      return #calls_to("deletePullRequestReviewComment") == 1
    end, 25))
    assert.is_true(vim.list_contains(calls_to("deletePullRequestReviewComment")[1], "id=PRRC_kwDOU6Rmbc74w1gd"))
    assert.is_true(vim.wait(5000, function()
      return Sidebar.lines()[1]:find("5 comments", 1, true) ~= nil
    end, 25))
  end)

  it("asks, then deletes the draft on a row with d", function()
    local pr = open_with_review_comments()
    drafts.keep(pr, { path = "alpha.txt", line = 6, start_line = 5, head = pr.head, body = "a draft" })
    choice = "Yes"
    gh.fixture("find-pending-review")
    gh.fixture("review-comments-paginate-slurp")

    press_on("alpha.txt:5-6", "d")

    assert.is_true(vim.wait(5000, function()
      return #drafts.list(pr) == 0
    end, 25))
    assert.same({ "Delete the draft on lines 5-6 of alpha.txt?" }, asked)
    assert.is_nil(line_of("a draft"))
  end)

  it("deletes nothing with d on a row that lists no comment", function()
    open_with_review_comments()

    press_on("other.lua", "d")

    assert.same({}, asked)
  end)
end)
