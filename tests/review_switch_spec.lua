local gh = require("support.gh")
local support = require("support.git")
local gutter = require("support.gutter")

local await, await_all, await_cached, edit, revision, settle =
  gutter.await, gutter.await_all, gutter.await_cached, gutter.edit, gutter.revision, gutter.settle

describe("the gutter's base", function()
  local dir, cwd

  before_each(function()
    cwd = vim.fn.getcwd()
    dir = gutter.repo()
  end)

  after_each(function()
    gutter.teardown(dir, cwd)
    vim.env.FAKE_GH_PR, vim.env.FAKE_GH_DELAY = nil, nil
  end)

  it("moves attached buffers to the new merge base after an external branch switch", function()
    local files = { "a.txt", "b.txt", "c.txt", "d.txt" }
    gutter.fixture(dir, "switched", files)
    support.git({ "switch", "-q", "main" }, dir)
    gutter.advance(dir)
    vim.fn.chdir(dir)

    local bufs = edit(files)
    assert.is_true(await_cached(bufs))
    assert.is_true(await(bufs, gutter.merge_base(dir), 10000))

    support.git({ "switch", "-q", "switched" }, dir)

    assert.is_true(await(bufs, gutter.merge_base(dir), 10000))
  end)

  it("moves attached buffers to the merge base after a switch to a branch named in hex digits", function()
    local files = { "a.txt", "b.txt" }
    gutter.fixture(dir, "20261008", files)
    support.git({ "switch", "-q", "main" }, dir)
    gutter.advance(dir)
    vim.fn.chdir(dir)
    local bufs = edit(files)
    assert.is_true(await_cached(bufs))
    assert.is_true(await(bufs, gutter.merge_base(dir), 10000))

    support.git({ "switch", "-q", "20261008" }, dir)

    assert.is_true(await(bufs, gutter.merge_base(dir), 10000))
  end)

  it("moves buffers onto the default branch's own base after an external switch to it", function()
    local files = { "a.txt", "b.txt" }
    gutter.fixture(dir, "left", files)
    support.git({ "switch", "-q", "main" }, dir)
    gutter.advance(dir)
    local main_tip = support.git({ "rev-parse", "HEAD" }, dir)
    support.git({ "switch", "-q", "left" }, dir)
    vim.fn.chdir(dir)
    local bufs = edit(files)
    assert.is_true(await(bufs, gutter.merge_base(dir), 10000))

    support.git({ "switch", "-q", "main" }, dir)

    assert.is_true(await(bufs, main_tip, 10000))
  end)

  it("keeps what is applied, asking nothing, while HEAD is detached", function()
    local fork_point = require("changeset.fork_point")
    local files = { "a.txt" }
    gutter.fixture(dir, "picking", files)
    vim.fn.chdir(dir)
    local bufs = edit(files)
    local base = gutter.merge_base(dir)
    assert.is_true(await(bufs, base, 10000))
    local get, asked = fork_point.get, {}
    fork_point.get = function(root, branch)
      asked[#asked + 1] = branch
      return get(root, branch)
    end

    support.git({ "switch", "-q", "--detach" }, dir)
    local detached = vim.wait(10000, function()
      local status = vim.b[bufs[1]].gitsigns_status_dict
      return status ~= nil and status.head ~= "picking"
    end, 25)
    settle()
    fork_point.get = get

    assert.is_true(detached, "gitsigns never saw HEAD detach")
    assert.same({}, asked)
    assert.is_true(await(bufs, base, 1000))
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
      gutter.advance(dir)

      local bufs = edit({ "a.txt" })
      assert.is_true(await_cached(bufs))
      assert.is_true(await(bufs, gutter.merge_base(dir), 5000))

      support.git({ "switch", "-q", "lone-" .. i }, dir)
      local base = gutter.merge_base(dir)
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
    local theirs = gutter.merge_base(other)
    gutter.fixture(dir, "scoped", { "a.txt" })
    support.git({ "switch", "-q", "main" }, dir)
    gutter.advance(dir)
    vim.fn.chdir(dir)

    local ours = edit({ "a.txt" })
    assert.is_true(await(ours, gutter.merge_base(dir), 5000))
    local their_bufs = edit({ other .. "/x.txt" })
    assert.is_true(await(their_bufs, theirs, 5000))

    support.git({ "switch", "-q", "scoped" }, dir)
    assert.is_true(await(ours, gutter.merge_base(dir), 10000))

    assert.is_true(settle())
    vim.fn.delete(other, "rf")
    assert.equal(theirs, revision(their_bufs[1]))
  end)

  it("leaves gitsigns' own blob buffers alone", function()
    gutter.fixture(dir, "blob", { "a.txt" })
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
    assert.is_true(await(bufs, gutter.merge_base(dir), 10000))

    assert.is_true(settle())
    assert.is_nil(revision(blob))
  end)

  it("moves each buffer onto a new base once after a switch", function()
    local files = {}
    for i = 1, 18 do
      files[i] = i .. ".txt"
    end
    gutter.fixture(dir, "counted", files)
    support.git({ "switch", "-q", "main" }, dir)
    gutter.advance(dir)
    vim.fn.chdir(dir)

    local bufs = edit(vim.list_slice(files, 1, 12))
    assert.is_true(await_cached(bufs))
    assert.is_true(await(bufs, gutter.merge_base(dir), 5000))

    local before = gutter.moves

    support.git({ "switch", "-q", "counted" }, dir)
    local base = gutter.merge_base(dir)
    -- The first buffer reaching the base marks the switch; the rest attach on the
    -- index while the moves run, and move once each.
    assert.is_true(vim.wait(10000, function()
      return revision(bufs[1]) == base
    end, 1))
    vim.list_extend(bufs, edit(vim.list_slice(files, 13, 18)))

    assert.is_true(await(bufs, base, 10000))
    assert.is_true(settle())
    assert.equal(18, gutter.moves - before)
  end)

  it("follows a pull on the default branch onto its new base", function()
    vim.fn.writefile({ "one" }, dir .. "/a.txt")
    local pushed = support.commit("pushed", dir)
    support.git({ "update-ref", "refs/remotes/origin/main", pushed }, dir)
    vim.fn.chdir(dir)
    local bufs = edit({ "a.txt" })
    assert.is_true(await(bufs, pushed, 5000))

    vim.fn.writefile({ "one", "two" }, dir .. "/a.txt")
    local pulled = support.commit("pulled", dir)
    support.git({ "update-ref", "refs/remotes/origin/main", pulled }, dir)

    assert.is_true(await(bufs, pulled, 10000))
  end)

  it("follows a push on the default branch onto its new base once Neovim regains focus", function()
    vim.fn.writefile({ "one" }, dir .. "/a.txt")
    local pushed = support.commit("pushed", dir)
    support.git({ "update-ref", "refs/remotes/origin/main", pushed }, dir)
    vim.fn.writefile({ "one", "two" }, dir .. "/a.txt")
    local unpushed = support.commit("unpushed", dir)
    vim.fn.chdir(dir)
    local bufs = edit({ "a.txt" })
    assert.is_true(await(bufs, pushed, 5000))
    assert.is_true(settle())

    support.git({ "update-ref", "refs/remotes/origin/main", unpushed }, dir)
    vim.api.nvim_exec_autocmds("FocusGained", {})

    assert.is_true(await(bufs, unpushed, 10000))
  end)

  it("follows the base the sidebar measures again as it reopens", function()
    gutter.fixture(dir, "merged-in-part", { "a.txt" })
    gutter.advance(dir)
    vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "main" })
    vim.fn.chdir(dir)
    local bufs = edit({ "a.txt" })
    assert.is_true(await(bufs, gutter.merge_base(dir), 5000))
    local changeset = require("changeset")
    changeset.open()
    changeset.close()
    assert.is_true(settle())

    -- Its first commit merged into main, which moves the fork point and leaves HEAD where it was.
    local first = support.git({ "rev-parse", "HEAD~1" }, dir)
    support.git({ "update-ref", "refs/heads/main", first }, dir)
    changeset.open()

    assert.is_true(await(bufs, first, 10000))
    changeset.close()
  end)

  it("stays on the base HEAD moved it to when a slow gh answer lands after", function()
    vim.fn.writefile({ "one" }, dir .. "/a.txt")
    local pushed = support.commit("pushed", dir)
    support.git({ "update-ref", "refs/remotes/origin/main", pushed }, dir)
    vim.env.FAKE_GH_DELAY = "2"
    vim.fn.chdir(dir)
    local bufs = edit({ "a.txt" })
    assert.is_true(await(bufs, pushed, 5000))

    vim.fn.writefile({ "one", "two" }, dir .. "/a.txt")
    local pulled = support.commit("pulled", dir)
    support.git({ "update-ref", "refs/remotes/origin/main", pulled }, dir)
    assert.is_true(await(bufs, pulled, 10000))

    assert.is_false(vim.wait(3000, function()
      return revision(bufs[1]) ~= pulled
    end, 20))
  end)

  it("follows a branch rebased onto a newer default branch to its new fork point", function()
    local files = { "a.txt" }
    gutter.fixture(dir, "rebased", files)
    support.git({ "switch", "-q", "main" }, dir)
    gutter.advance(dir)
    local main_tip = support.git({ "rev-parse", "HEAD" }, dir)
    support.git({ "switch", "-q", "rebased" }, dir)
    vim.fn.chdir(dir)
    local bufs = edit(files)
    assert.is_true(await(bufs, gutter.merge_base(dir), 10000))

    support.git({ "rebase", "-q", "main" }, dir)

    assert.is_true(await(bufs, main_tip, 10000))
  end)

  it("moves a buffer that lost its base once, across a burst of updates", function()
    local files = { "a.txt", "b.txt", "c.txt", "d.txt" }
    gutter.fixture(dir, "burst", files)
    vim.fn.chdir(dir)
    local base = gutter.merge_base(dir)
    local bufs = edit(files)
    assert.is_true(await(bufs, base, 10000))
    assert.is_true(settle())

    -- As if every buffer had attached on the old base, then caught a burst of
    -- events before its move landed.
    for _, buf in ipairs(bufs) do
      require("gitsigns.cache").cache[buf].git_obj.revision = nil
    end
    local before = gutter.moves
    for _ = 1, 3 do
      vim.api.nvim_exec_autocmds("User", { pattern = "GitSignsUpdate" })
    end

    assert.is_true(await(bufs, base, 10000))
    assert.is_true(settle())
    assert.equal(#bufs, gutter.moves - before)
  end)
end)
