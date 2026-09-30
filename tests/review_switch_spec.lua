local support = require("support.git")
local review = require("support.pr_review")

local await, await_all, await_cached, edit, revision, settle =
  review.await, review.await_all, review.await_cached, review.edit, review.revision, review.settle

describe("PR Review Mode", function()
  local dir, cwd

  before_each(function()
    cwd = vim.fn.getcwd()
    dir = review.repo()
  end)

  after_each(function()
    review.teardown(dir, cwd)
  end)

  it("moves attached buffers to the new merge base after an external branch switch", function()
    local files = { "a.txt", "b.txt", "c.txt", "d.txt" }
    review.fixture(dir, "switched", files)
    support.git({ "switch", "-q", "main" }, dir)
    vim.fn.chdir(dir)

    local bufs = edit(files)
    assert.is_true(await_cached(bufs))

    support.git({ "switch", "-q", "switched" }, dir)

    assert.is_true(await(bufs, review.merge_base(dir), 10000))
  end)

  it("moves buffers back to the index after an external switch to the default branch", function()
    local files = { "a.txt", "b.txt" }
    review.fixture(dir, "left", files)
    vim.fn.chdir(dir)
    local bufs = edit(files)
    assert.is_true(await(bufs, review.merge_base(dir), 10000))

    support.git({ "switch", "-q", "main" }, dir)

    assert.is_true(await(bufs, nil, 10000))
  end)

  it("keeps a lone buffer on the merge base after an external branch switch", function()
    vim.fn.chdir(dir)
    for i = 1, 5 do
      vim.fn.writefile({ "base " .. i }, dir .. "/a.txt")
      support.commit("base " .. i, dir)
      support.git({ "switch", "-q", "-c", "lone-" .. i }, dir)
      vim.fn.writefile({ "base " .. i, "change" }, dir .. "/a.txt")
      support.commit("change " .. i, dir)
      support.git({ "switch", "-q", "main" }, dir)

      local bufs = edit({ "a.txt" })
      assert.is_true(await_cached(bufs))
      assert.is_true(await(bufs, nil, 5000))

      support.git({ "switch", "-q", "lone-" .. i }, dir)
      local base = review.merge_base(dir)
      assert.is_true(await(bufs, base, 10000), "iteration " .. i)
      assert.is_false(vim.wait(500, function()
        return revision(bufs[1]) ~= base
      end, 20))

      vim.cmd("silent! %bwipeout!")
      support.git({ "switch", "-q", "main" }, dir)
    end
  end)

  it("leaves buffers from another repository alone", function()
    local other = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(other, "p")
    support.init_repo("main", other)
    vim.fn.writefile({ "one" }, other .. "/x.txt")
    support.commit("base", other)
    review.fixture(dir, "scoped", { "a.txt" })
    support.git({ "switch", "-q", "main" }, dir)
    vim.fn.chdir(dir)

    local bufs = edit({ "a.txt", other .. "/x.txt" })
    assert.is_true(await_cached(bufs))
    assert.is_true(await(bufs, nil, 5000))

    support.git({ "switch", "-q", "scoped" }, dir)
    assert.is_true(await({ bufs[1] }, review.merge_base(dir), 10000))

    assert.is_true(settle())
    vim.fn.delete(other, "rf")
    assert.is_nil(revision(bufs[2]))
  end)

  it("leaves gitsigns' own blob buffers alone", function()
    review.fixture(dir, "blob", { "a.txt" })
    support.git({ "switch", "-q", "main" }, dir)
    vim.fn.chdir(dir)
    local bufs = edit({ "a.txt" })
    -- diffthis reuses the source buffer's comparison text, set by its first update.
    assert.is_true(await_all(bufs, function(buf)
      local bcache = require("gitsigns.cache").cache[buf]
      return bcache ~= nil and bcache.compare_text ~= nil
    end, 5000))
    require("gitsigns").diffthis()
    local blob
    assert.is_true(vim.wait(5000, function()
      blob = vim.iter(pairs(require("gitsigns.cache").cache)):find(function(buf)
        return vim.api.nvim_buf_get_name(buf):match("^gitsigns://")
      end)
      return blob ~= nil
    end, 20))
    assert.is_nil(revision(blob))

    support.git({ "switch", "-q", "blob" }, dir)
    assert.is_true(await(bufs, review.merge_base(dir), 10000))

    assert.is_true(settle())
    assert.is_nil(revision(blob))
  end)

  it("moves each buffer onto a new base once after a switch", function()
    local files = {}
    for i = 1, 18 do
      files[i] = i .. ".txt"
    end
    review.fixture(dir, "counted", files)
    support.git({ "switch", "-q", "main" }, dir)
    vim.fn.chdir(dir)

    local bufs = edit(vim.list_slice(files, 1, 12))
    assert.is_true(await_cached(bufs))
    assert.is_true(await(bufs, nil, 5000))

    local before = review.moves

    support.git({ "switch", "-q", "counted" }, dir)
    local base = review.merge_base(dir)
    -- The first buffer reaching the base marks the switch; the rest attach while
    -- the moves run, onto the base already.
    assert.is_true(vim.wait(10000, function()
      return revision(bufs[1]) == base
    end, 1))
    vim.list_extend(bufs, edit(vim.list_slice(files, 13, 18)))

    assert.is_true(await(bufs, base, 10000))
    assert.is_true(settle())
    assert.equal(12, review.moves - before)
  end)

  it("moves a buffer that lost its base once, across a burst of updates", function()
    local files = { "a.txt", "b.txt", "c.txt", "d.txt" }
    review.fixture(dir, "burst", files)
    vim.fn.chdir(dir)
    local base = review.merge_base(dir)
    local bufs = edit(files)
    assert.is_true(await(bufs, base, 10000))
    assert.is_true(settle())

    -- As if every buffer had attached on the old base, then caught a burst of
    -- events before its move landed.
    for _, buf in ipairs(bufs) do
      require("gitsigns.cache").cache[buf].git_obj.revision = nil
    end
    local before = review.moves
    for _ = 1, 3 do
      vim.api.nvim_exec_autocmds("User", { pattern = "GitSignsUpdate" })
    end

    assert.is_true(await(bufs, base, 10000))
    assert.is_true(settle())
    assert.equal(#bufs, review.moves - before)
  end)
end)
