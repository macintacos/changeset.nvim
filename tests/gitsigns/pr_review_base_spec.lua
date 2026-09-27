local support = require("support.git")
local review = require("support.pr_review")

local await, await_cached, edit, revision = review.await, review.await_cached, review.edit, review.revision

describe("PR Review Mode", function()
  local dir, cwd

  before_each(function()
    cwd = vim.fn.getcwd()
    dir = review.repo()
  end)

  after_each(function()
    review.teardown(dir, cwd)
  end)

  it("diffs a single edited file against the merge base", function()
    review.fixture(dir, "single", { "a.txt" })
    vim.fn.chdir(dir)

    local bufs = edit({ "a.txt" })

    assert.is_true(await(bufs, review.merge_base(dir), 5000))
  end)

  it("gives every buffer loaded in the same tick the merge base", function()
    review.fixture(dir, "burst", { "a.txt", "b.txt", "c.txt" })
    vim.fn.chdir(dir)

    local bufs = edit({ "a.txt", "b.txt", "c.txt" })

    assert.is_true(await(bufs, review.merge_base(dir), 5000))
  end)

  it("leaves a base set by hand alone", function()
    vim.fn.writefile({ "one" }, dir .. "/a.txt")
    vim.fn.writefile({ "one" }, dir .. "/b.txt")
    support.commit("base", dir)
    local parent = support.git({ "rev-parse", "HEAD~1" }, dir)
    vim.fn.chdir(dir)

    local bufs = edit({ "a.txt", "b.txt" })
    assert.is_true(await_cached(bufs))
    vim.api.nvim_buf_call(bufs[1], function()
      require("gitsigns").change_base(parent)
    end)
    assert.is_true(await({ bufs[1] }, parent, 5000))

    vim.api.nvim_buf_set_lines(bufs[2], 0, -1, false, { "edited" })

    assert.is_false(vim.wait(1500, function()
      return revision(bufs[1]) ~= parent
    end, 20))
  end)
end)
