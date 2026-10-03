local build = require("changeset.build")
local changeset = require("changeset")
local drafts = require("changeset.drafts")
local pending_state = require("changeset.pending_state")
local render = require("changeset.render")
local window = require("changeset.window")
local Fixture = require("support.git")
local gh = require("support.gh")

-- A file of its own: a find still in flight from an earlier case would take the answers a
-- later one queues.
describe(":Changeset pr submit", function()
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
    changeset.close()
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
    vim.env.FAKE_GH_PR = nil
    gh.reset()
  end)

  ---@param buf integer
  ---@return vim.api.keyset.extmark_details[]
  local function mark_details(buf)
    local ns = vim.api.nvim_get_namespaces()["changeset.review_comments"]
    return vim.tbl_map(function(mark)
      return mark[4]
    end, vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }))
  end

  ---The group drawing the header's circle, or nil when it shows none.
  ---@return string?
  local function circle_group()
    local win = assert(window.win())
    local shown =
      vim.api.nvim_eval_statusline(vim.wo[win].winbar, { use_winbar = true, winid = win, highlights = true })
    local circle_at = shown.str:find("●", 1, true)
    if not circle_at then
      return nil
    end
    local group
    for _, mark in ipairs(shown.highlights) do
      if mark.start <= circle_at - 1 then
        group = mark.group
      end
    end
    return group
  end

  it("submits the pending review, leaving the header gray and only the drafts drawn", function()
    gh.fixture("find-pending-review")
    gh.fixture("review-comments-paginate-slurp")
    vim.cmd.edit("alpha.txt")
    local alpha = vim.api.nvim_get_current_buf()
    changeset.open()
    local found
    assert.is_true(vim.wait(10000, function()
      local tree = build.current()
      found = tree and tree.pr and pending_state.get(tree.root, tree.pr)
      return found ~= nil
    end, 25))
    drafts.keep(found.pr, { path = "alpha.txt", line = 6, start_line = 5, head = found.pr.head, body = "draft" })
    assert.is_true(vim.wait(10000, function()
      return #mark_details(alpha) == 5 and circle_group() == render.HEADER_PENDING_HL
    end, 25))

    gh.fixture("find-pending-review")
    gh.fixture("review-comments-paginate-slurp")
    gh.fixture("submit-comment-one-review-comment-no-body")
    gh.fixture("find-pending-review-empty")
    vim.cmd("runtime plugin/changeset.lua")
    vim.api.nvim_set_current_win(vim.fn.bufwinid(alpha))
    vim.cmd("Changeset pr submit")
    assert.is_true(vim.wait(10000, function()
      return vim.api.nvim_win_get_config(0).relative ~= ""
    end, 25))
    vim.fn.maparg("<CR>", "n", false, true).callback()

    assert.is_true(vim.wait(10000, function()
      return circle_group() == render.HEADER_NOT_PENDING_HL
    end, 25))
    local details = mark_details(alpha)
    assert.are.equal(1, #details)
    assert.are.same({ "○ ", "ChangesetReviewDraft" }, details[1].virt_text[1])
    local submit = vim.iter(gh.calls()):find(function(args)
      return vim.iter(args):any(function(arg)
        return arg:find("submitPullRequestReview", 1, true) ~= nil
      end)
    end)
    assert.truthy(vim.tbl_contains(submit, "event=COMMENT"))
    assert.is_false(vim.iter(submit):any(function(arg)
      return vim.startswith(arg, "body=")
    end))
  end)
end)
