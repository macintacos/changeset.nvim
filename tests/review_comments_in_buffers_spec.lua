local build = require("changeset.build")
local changeset = require("changeset")
local drafts = require("changeset.drafts")
local Fixture = require("support.git")
local gh = require("support.gh")

-- A file of its own: a find still in flight from an earlier case would take the answers a
-- later one queues.
describe("review comments in buffers", function()
  local tmp, previous_dir

  before_each(function()
    tmp, previous_dir = Fixture.enter_tempdir()
    Fixture.init_repo("trunk", tmp)
    Fixture.git({ "checkout", "-q", "-b", "feature" }, tmp)
    local lines = {}
    for i = 1, 40 do
      lines[i] = "alpha " .. i
    end
    vim.fn.writefile(lines, "alpha.txt")
    Fixture.commit("alpha", tmp)
    vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "trunk", number = 1 })
    os.remove(drafts.path())
  end)

  after_each(function()
    changeset.setup()
    changeset.close()
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
    vim.env.FAKE_GH_PR = nil
    gh.reset()
  end)

  ---@param buf integer
  ---@return integer
  local function mark_count(buf)
    local ns = vim.api.nvim_get_namespaces()["changeset.review_comments"]
    return #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
  end

  ---@param buf integer
  ---@return vim.api.keyset.extmark_details[]
  local function mark_details(buf)
    local ns = vim.api.nvim_get_namespaces()["changeset.review_comments"]
    return vim.tbl_map(function(mark)
      return mark[4]
    end, vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }))
  end

  ---Opens alpha.txt and the sidebar, waiting until GitHub's answer for the PR is kept.
  ---@return integer alpha
  ---@return changeset.Pr pr
  local function open_kept(fixture)
    gh.fixture(fixture)
    vim.cmd.edit("alpha.txt")
    local alpha = vim.api.nvim_get_current_buf()
    changeset.open()
    local found
    assert.is_true(vim.wait(10000, function()
      local tree = build.current()
      found = tree and tree.pr and require("changeset.pending_state").get(tree.root, tree.pr)
      return found ~= nil
    end, 25))
    return alpha, found.pr
  end

  ---@param pr changeset.Pr
  ---@param head string
  ---@return changeset.Draft
  local function keep_draft(pr, head)
    local draft = { path = "alpha.txt", line = 6, start_line = 5, head = head, body = "draft one\nmore" }
    drafts.keep(pr, draft)
    return draft
  end

  it("marks a draft at the PR's head with a hollow circle in its own group", function()
    local alpha, pr = open_kept("find-pending-review-empty")
    keep_draft(pr, pr.head)
    local details = mark_details(alpha)
    assert.are.equal(1, #details)
    assert.are.same({ "○ ", "ChangesetReviewDraft" }, details[1].virt_text[1])
    assert.are.same({ "draft one", "ChangesetReviewCommentBody" }, details[1].virt_text[2])
    assert.are.equal("ChangesetReviewDraft", details[1].number_hl_group)
  end)

  it("tells a statuscolumn a draft's bubble that the sign column leaves out", function()
    changeset.setup({ review_comment = { sign = false } })
    local alpha, pr = open_kept("find-pending-review-empty")
    keep_draft(pr, pr.head)
    assert.are.same({ "󰍪", "ChangesetReviewDraft" }, { changeset.bubble(alpha, 5) })
  end)

  it("draws no draft written against another head", function()
    local alpha, pr = open_kept("find-pending-review-empty")
    keep_draft(pr, "0000000000000000000000000000000000000000")
    assert.are.equal(0, mark_count(alpha))
  end)

  it("removes a draft's mark when the draft is dropped", function()
    local alpha, pr = open_kept("find-pending-review-empty")
    local draft = keep_draft(pr, pr.head)
    assert.are.equal(1, mark_count(alpha))
    drafts.drop(pr, draft)
    assert.are.equal(0, mark_count(alpha))
  end)

  it("follows a branch switch with a draft", function()
    local alpha, pr = open_kept("find-pending-review-empty")
    keep_draft(pr, pr.head)
    assert.are.equal(1, mark_count(alpha))

    vim.env.FAKE_GH_PR = nil
    Fixture.git({ "checkout", "-q", "-b", "other" }, tmp)
    vim.api.nvim_exec_autocmds("User", { pattern = "GitSignsUpdate" })
    assert.is_true(vim.wait(10000, function()
      return mark_count(alpha) == 0
    end, 25))

    vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "trunk", number = 1 })
    gh.fixture("find-pending-review-empty")
    Fixture.git({ "checkout", "-q", "feature" }, tmp)
    vim.api.nvim_exec_autocmds("User", { pattern = "GitSignsUpdate" })
    -- The kept answer redraws the draft at once; the find this checkout starts must still
    -- take its answer here, not a later case's.
    assert.is_true(vim.wait(10000, function()
      local finds = vim.tbl_filter(function(call)
        return call[1] == "api"
      end, gh.calls())
      return mark_count(alpha) == 1 and #finds == 2
    end, 25))
  end)

  it("follows the pending review, focus and a branch switch", function()
    gh.fixture("find-pending-review")
    gh.fixture("review-comments-paginate-slurp")
    vim.cmd.edit("alpha.txt")
    local alpha = vim.api.nvim_get_current_buf()
    changeset.open()
    assert.is_true(vim.wait(10000, function()
      return mark_count(alpha) == 4
    end, 25))

    gh.fixture("find-pending-review-empty")
    vim.api.nvim_exec_autocmds("FocusGained", {})
    assert.is_true(vim.wait(10000, function()
      return mark_count(alpha) == 0
    end, 25))

    gh.fixture("find-pending-review")
    gh.fixture("review-comments-paginate-slurp")
    vim.api.nvim_exec_autocmds("FocusGained", {})
    assert.is_true(vim.wait(10000, function()
      return mark_count(alpha) == 4
    end, 25))

    vim.env.FAKE_GH_PR = nil
    Fixture.git({ "checkout", "-q", "-b", "other" }, tmp)
    vim.api.nvim_exec_autocmds("User", { pattern = "GitSignsUpdate" })
    assert.is_true(vim.wait(10000, function()
      return mark_count(alpha) == 0
    end, 25))
    assert.are.equal("other", build.current().branch)
  end)
end)
