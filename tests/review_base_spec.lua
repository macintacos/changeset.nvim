local support = require("support.git")
local gutter = require("support.gutter")
local present = require("support.present")

local await, await_cached, edit, revision = gutter.await, gutter.await_cached, gutter.edit, gutter.revision

describe("the gutter's base", function()
  local dir ---@type string
  local cwd ---@type string
  local outside ---@type string?
  local other ---@type string?

  before_each(function()
    cwd = vim.fn.getcwd()
    dir = gutter.repo()
  end)

  after_each(function()
    gutter.teardown(dir, cwd)
    if outside then
      vim.fn.delete(outside, "rf")
    end
    if other then
      vim.fn.delete(other, "rf")
    end
    outside, other = nil, nil
  end)

  it("diffs a single edited file against the merge base, with no setup() call", function()
    gutter.fixture(dir, "single", { "a.txt" })
    vim.fn.chdir(dir)

    local bufs = edit({ "a.txt" })

    assert.is_true(await(bufs, gutter.merge_base(dir), 5000))
  end)

  it("gives every buffer loaded in the same tick the merge base", function()
    gutter.fixture(dir, "burst", { "a.txt", "b.txt", "c.txt" })
    vim.fn.chdir(dir)

    local bufs = edit({ "a.txt", "b.txt", "c.txt" })

    assert.is_true(await(bufs, gutter.merge_base(dir), 5000))
  end)

  it("leaves a base set by hand alone", function()
    vim.fn.writefile({ "one" }, dir .. "/a.txt")
    vim.fn.writefile({ "one" }, dir .. "/b.txt")
    support.commit("base", dir)
    local parent = support.git({ "rev-parse", "HEAD~1" }, dir)
    vim.fn.chdir(dir)

    local bufs = edit({ "a.txt", "b.txt" })
    assert.is_true(await(bufs, gutter.merge_base(dir), 5000))
    vim.api.nvim_buf_call(present(bufs[1]), function()
      require("gitsigns").change_base(parent)
    end)
    assert.is_true(await({ bufs[1] }, parent, 5000))

    vim.api.nvim_buf_set_lines(present(bufs[2]), 0, -1, false, { "edited" })

    assert.is_false(vim.wait(1500, function()
      return revision(present(bufs[1])) ~= parent
    end, 20))
  end)

  it("diffs against the merge base of the buffer's own repository", function()
    gutter.fixture(dir, "elsewhere", { "a.txt" })
    outside = support.enter_tempdir()

    local bufs = edit({ dir .. "/a.txt" })

    assert.is_true(await(bufs, gutter.merge_base(dir), 5000))
  end)

  it("measures a branch name two repositories share in each one's own repository", function()
    other = gutter.repo()
    vim.fn.writefile({ "one" }, other .. "/b.txt")
    support.commit("base", other)
    local theirs = edit({ other .. "/b.txt" })
    assert.is_true(await_cached(theirs))
    gutter.fixture(dir, "shared", { "a.txt" })
    assert.is_true(await(edit({ dir .. "/a.txt" }), gutter.merge_base(dir), 5000))

    support.git({ "switch", "-q", "-c", "shared" }, other)
    vim.fn.writefile({ "one", "two" }, other .. "/b.txt")
    support.commit("change", other)
    assert.is_true(vim.wait(5000, function()
      return vim.b[theirs[1]].gitsigns_head == "shared"
    end, 20))

    assert.is_true(await(theirs, gutter.merge_base(other), 5000))
  end)

  it("leaves a repository with no fork point off the other repository's base", function()
    other = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(other, "p")
    support.init_repo("dev", other)
    vim.fn.writefile({ "one" }, other .. "/b.txt")
    support.commit("base", other)
    local theirs = edit({ other .. "/b.txt" })
    assert.is_true(await_cached(theirs))
    gutter.fixture(dir, "forked", { "a.txt" })
    local base = gutter.merge_base(dir)
    assert.is_true(await(edit({ dir .. "/a.txt" }), base, 5000))
    assert.is_true(gutter.settle())
    local moves = gutter.moves_to[base]

    vim.api.nvim_set_current_buf(present(theirs[1]))
    vim.api.nvim_buf_set_lines(present(theirs[1]), 0, -1, false, { "edited" })

    assert.is_false(vim.wait(1500, function()
      return gutter.moves_to[base] ~= moves
    end, 20))
    assert.is_nil(revision(present(theirs[1])))
  end)

  it("diffs a buffer opened from a second repository against that repository's merge base", function()
    gutter.fixture(dir, "first", { "a.txt" })
    local ours = edit({ dir .. "/a.txt" })
    local base = gutter.merge_base(dir)
    assert.is_true(await(ours, base, 5000))
    other = gutter.repo()
    gutter.fixture(other, "second", { "b.txt" })

    local theirs = edit({ other .. "/b.txt" })

    assert.is_true(await(theirs, gutter.merge_base(other), 5000))
    assert.is_true(await(ours, base, 5000))
  end)
end)
