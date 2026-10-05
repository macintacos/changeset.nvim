local build = require("changeset.build")
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
    vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "trunk", number = 1 })
    os.remove(drafts.path())
  end)

  after_each(function()
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
end)
