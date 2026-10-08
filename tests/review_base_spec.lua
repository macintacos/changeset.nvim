local support = require("support.git")
local review = require("support.pr_review")
local Notify = require("support.notify")

local await, await_cached, edit, revision = review.await, review.await_cached, review.edit, review.revision

describe("PR Review Mode", function()
  local dir, cwd, outside, other

  before_each(function()
    cwd = vim.fn.getcwd()
    dir = review.repo()
  end)

  after_each(function()
    review.teardown(dir, cwd)
    for _, extra in ipairs({ outside, other }) do
      vim.fn.delete(extra, "rf")
    end
    outside, other = nil, nil
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

  it("diffs against the merge base of the buffer's own repository", function()
    review.fixture(dir, "elsewhere", { "a.txt" })
    outside = support.enter_tempdir()

    local bufs = edit({ dir .. "/a.txt" })

    assert.is_true(await(bufs, review.merge_base(dir), 5000))
  end)

  it("toggles the tracked buffers from a buffer gitsigns does not track", function()
    review.fixture(dir, "untracked", { "a.txt" })
    outside = support.enter_tempdir()
    local bufs = edit({ dir .. "/a.txt" })
    local base = review.merge_base(dir)
    assert.is_true(await(bufs, base, 5000))
    vim.cmd.enew()

    require("changeset.review").toggle()
    assert.is_true(await(bufs, nil, 5000))
    require("changeset.review").toggle()

    assert.is_true(await(bufs, base, 5000))
  end)

  it("measures a branch name two repositories share in each one's own repository", function()
    other = review.repo()
    vim.fn.writefile({ "one" }, other .. "/b.txt")
    support.commit("base", other)
    local theirs = edit({ other .. "/b.txt" })
    assert.is_true(await_cached(theirs))
    review.fixture(dir, "shared", { "a.txt" })
    assert.is_true(await(edit({ dir .. "/a.txt" }), review.merge_base(dir), 5000))

    support.git({ "switch", "-q", "-c", "shared" }, other)
    vim.fn.writefile({ "one", "two" }, other .. "/b.txt")
    support.commit("change", other)
    assert.is_true(vim.wait(5000, function()
      return vim.b[theirs[1]].gitsigns_head == "shared"
    end, 20))

    assert.is_true(await(theirs, review.merge_base(other), 5000))
  end)

  it("leaves a repository with no fork point off the other repository's base", function()
    other = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(other, "p")
    support.init_repo("dev", other)
    vim.fn.writefile({ "one" }, other .. "/b.txt")
    support.commit("base", other)
    local theirs = edit({ other .. "/b.txt" })
    assert.is_true(await_cached(theirs))
    review.fixture(dir, "forked", { "a.txt" })
    local base = review.merge_base(dir)
    assert.is_true(await(edit({ dir .. "/a.txt" }), base, 5000))
    assert.is_true(review.settle())
    local moves = review.moves_to[base]

    vim.api.nvim_set_current_buf(theirs[1])
    vim.api.nvim_buf_set_lines(theirs[1], 0, -1, false, { "edited" })

    assert.is_false(vim.wait(1500, function()
      return review.moves_to[base] ~= moves
    end, 20))
    assert.is_nil(revision(theirs[1]))
  end)

  it("diffs a buffer opened from a second repository against that repository's merge base", function()
    review.fixture(dir, "first", { "a.txt" })
    local ours = edit({ dir .. "/a.txt" })
    local base = review.merge_base(dir)
    assert.is_true(await(ours, base, 5000))
    other = review.repo()
    review.fixture(other, "second", { "b.txt" })

    local theirs = edit({ other .. "/b.txt" })

    assert.is_true(await(theirs, review.merge_base(other), 5000))
    assert.is_true(await(ours, base, 5000))
  end)

  it("keeps a branch switched off in one repository on in another with the same branch", function()
    review.fixture(dir, "x", { "a.txt" })
    local ours = edit({ dir .. "/a.txt" })
    assert.is_true(await(ours, review.merge_base(dir), 5000))
    require("changeset.review").toggle()
    assert.is_true(await(ours, nil, 5000))
    other = review.repo()
    review.fixture(other, "x", { "b.txt" })

    local theirs = edit({ other .. "/b.txt" })

    assert.is_true(await(theirs, review.merge_base(other), 5000))
  end)

  it("switches off from a buffer of the repository the mode left without re-entering it", function()
    other = review.repo()
    review.fixture(other, "left", { "b.txt" })
    local theirs = edit({ other .. "/b.txt" })
    local their_base = review.merge_base(other)
    assert.is_true(await(theirs, their_base, 5000))
    review.fixture(dir, "followed", { "a.txt" })
    assert.is_true(await(edit({ dir .. "/a.txt" }), review.merge_base(dir), 5000))
    vim.api.nvim_set_current_buf(theirs[1])
    assert.is_true(review.settle())
    local moves = review.moves_to[their_base]
    local notes, restore = Notify.capture()

    local ok, err = pcall(function()
      require("changeset.review").toggle()
      assert.is_true(await(theirs, nil, 5000))
      assert.is_true(review.settle())
    end)
    restore()

    assert(ok, err)
    assert.are.equal(moves, review.moves_to[their_base])
    assert.are.same({ "PR Review Mode: off" }, Notify.messages(notes))
  end)
end)
