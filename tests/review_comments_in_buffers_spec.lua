local build = require("changeset.build")
local changeset = require("changeset")
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
  ---@return integer
  local function mark_count(buf)
    local ns = vim.api.nvim_get_namespaces()["changeset.review_comments"]
    return #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
  end

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
