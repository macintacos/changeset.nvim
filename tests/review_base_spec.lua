local support = require("support.git")
local gutter = require("support.gutter")
local present = require("support.present")

local await, await_cached, edit, revision = gutter.await, gutter.await_cached, gutter.edit, gutter.revision

local Repo = require("gitsigns.git.repo")
---@cast Repo table
local read_text = Repo.get_show_text
---@type string? blob whose next read has a base move land under it
local held

---@async
---@param self Gitsigns.Repo
---@param object string
---@param encoding string?
---@return string[] stdout
---@return string? stderr
Repo.get_show_text = function(self, object, encoding)
  if object == held then
    held = nil
    -- The buffer-less GitSignsUpdate gitsigns sends after a chdir, landing mid-read.
    vim.api.nvim_exec_autocmds("User", { pattern = "GitSignsUpdate", modeline = false })
    gutter.settle()
  end
  return read_text(self, object, encoding)
end

---@param buf integer
---@return string[]?
local function text(buf)
  local bcache = require("gitsigns.cache").cache[buf]
  return bcache and bcache.compare_text
end

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
    held = nil
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

  it("diffs a buffer whose base moves while its first read runs against the merge base", function()
    gutter.fixture(dir, "mid", { "a.txt", "b.txt" })
    vim.fn.writefile({ "one", "two", "three" }, dir .. "/a.txt")
    support.git({ "add", "a.txt" }, dir)
    local base = gutter.merge_base(dir)
    -- gitsigns keeps the blob's final newline as an empty last line; support.git trims it.
    local want = vim.split(support.git({ "show", base .. ":a.txt" }, dir) .. "\n", "\n")
    vim.fn.chdir(dir)
    -- b.txt lands changeset's base first, so the move under a.txt's read is a.txt's only one.
    assert.is_true(await(edit({ "b.txt" }), base, 5000))
    held = support.git({ "rev-parse", ":a.txt" }, dir)

    local a = present(edit({ "a.txt" })[1])

    vim.wait(5000, function()
      return vim.deep_equal(text(a), want)
    end, 20)
    assert.is_nil(held) -- the read went through the hook, or the case proves nothing
    assert.are.same(want, text(a))
  end)
end)
