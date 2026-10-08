local gh = require("support.gh")
local support = require("support.git")
local review = require("support.pr_review")
local Notify = require("support.notify")
local toggle = require("changeset.review").toggle

local await, edit, revision, settle = review.await, review.edit, review.revision, review.settle

describe("PR Review Mode", function()
  local dir, cwd, restore_notify, change_base
  ---@type { msg: string, level: integer? }[]
  local notices

  ---A repo with `a.txt` changed on `parent`, then again on `child` cut from it.
  ---@param child string
  ---@param source string? What `child`'s reflog says it was created from: parent's tip commit, which names no
  ---parent, when absent.
  local function stack(child, source)
    review.fixture(dir, "parent", { "a.txt" })
    support.git({ "switch", "-q", "-c", child, source or support.git({ "rev-parse", "HEAD" }, dir) }, dir)
    vim.fn.writefile({ "one", "two", "three" }, dir .. "/a.txt")
    support.commit("child change", dir)
  end

  before_each(function()
    cwd = vim.fn.getcwd()
    dir = review.repo()
    notices, restore_notify = Notify.capture()
    change_base = require("gitsigns").change_base
  end)

  after_each(function()
    review.teardown(dir, cwd)
    vim.env.FAKE_GH_PR = nil
    vim.env.FAKE_GH_DELAY = nil
    restore_notify()
    require("gitsigns").change_base = change_base
  end)

  ---Every "on" notice, awaiting the first for up to `timeout` and a duplicate for a second.
  ---@param timeout integer
  ---@return string[]
  local function on_notices(timeout)
    local function on()
      return vim.tbl_filter(
        function(msg)
          return msg:match(": on ") ~= nil
        end,
        vim.tbl_map(function(n)
          return n.msg
        end, notices)
      )
    end
    vim.wait(timeout, function()
      return #on() > 0
    end, 20)
    vim.wait(1000, function()
      return #on() > 1
    end, 20)
    return on()
  end

  it("announces the PR's target branch once when toggled on", function()
    stack("stacked-announced")
    vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "parent" })
    vim.fn.chdir(dir)
    local bufs = edit({ "a.txt" })
    assert.is_true(await(bufs, review.merge_base(dir, "parent"), 5000))
    toggle()
    assert.is_true(await(bufs, nil, 5000))

    toggle()

    local on = on_notices(5000)
    assert.equal(1, #on)
    assert.matches("vs parent", on[1])
  end)

  it("announces the branch it was created from when toggled on", function()
    stack("created-from-parent", "parent")
    vim.fn.chdir(dir)
    local bufs = edit({ "a.txt" })
    assert.is_true(await(bufs, review.merge_base(dir, "parent"), 5000))
    toggle()
    assert.is_true(await(bufs, nil, 5000))

    toggle()

    local on = on_notices(5000)
    assert.equal(1, #on)
    assert.matches("vs parent", on[1])
  end)

  it("announces no success when the default-branch base fails to apply", function()
    review.fixture(dir, "announce-failed", { "a.txt" })
    vim.fn.chdir(dir)
    local bufs = edit({ "a.txt" })
    assert.is_true(await(bufs, review.merge_base(dir), 5000))
    toggle()
    assert.is_true(await(bufs, nil, 5000))
    assert.is_true(settle())
    require("gitsigns").change_base = function(_, _, cb)
      vim.schedule(function()
        cb("boom")
      end)
    end

    toggle()

    assert.is_true(vim.wait(5000, function()
      return vim.iter(notices):any(function(n)
        return n.level == vim.log.levels.ERROR
      end)
    end, 20))
    assert.same({}, on_notices(1000))
  end)

  it("falls back to the default-branch base, with a warning, when the PR target has no merge base", function()
    review.fixture(dir, "orphan-target", { "a.txt" })
    vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "gone" })
    vim.fn.chdir(dir)
    local bufs = edit({ "a.txt" })
    local base = review.merge_base(dir)
    assert.is_true(await(bufs, base, 5000))
    toggle()
    assert.is_true(await(bufs, nil, 5000))

    toggle()

    local on = on_notices(5000)
    assert.equal(1, #on)
    assert.matches("vs main", on[1])
    assert.is_true(vim.iter(notices):any(function(n)
      return n.level == vim.log.levels.WARN and n.msg:find("gone", 1, true) ~= nil
    end))
    assert.equal(base, revision(bufs[1]))
  end)

  it("turns on at the default-branch base when gh is not installed", function()
    review.fixture(dir, "no-gh", { "a.txt" })
    vim.fn.chdir(dir)
    local bufs = edit({ "a.txt" })
    local base = review.merge_base(dir)
    assert.is_true(await(bufs, base, 5000))
    toggle()
    assert.is_true(await(bufs, nil, 5000))

    local ok, err = pcall(gh.without, toggle)

    local on = on_notices(5000)
    assert(ok, err)
    assert.equal(1, #on)
    assert.is_true(await(bufs, base, 5000))
  end)

  it("keeps the mode off on a branch it was toggled off on, across a switch away and back", function()
    review.fixture(dir, "kept-off", { "a.txt" })
    vim.fn.chdir(dir)
    local bufs = edit({ "a.txt" })
    assert.is_true(await(bufs, review.merge_base(dir), 5000))
    toggle()
    assert.is_true(await(bufs, nil, 5000))

    for _, branch in ipairs({ "main", "kept-off" }) do
      support.git({ "switch", "-q", branch }, dir)
      assert.is_true(vim.wait(10000, function()
        return vim.b[bufs[1]].gitsigns_head == branch
      end, 20))
    end

    assert.is_true(settle())
    assert.is_nil(revision(bufs[1]))
  end)

  it("diffs a stacked branch against its PR's target branch", function()
    stack("stacked")
    vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "parent" })
    vim.fn.chdir(dir)

    local bufs = edit({ "a.txt" })

    assert.is_true(await(bufs, review.merge_base(dir, "parent"), 5000))
  end)

  it("drops a PR lookup that a toggle superseded", function()
    stack("stacked-toggled")
    vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "parent" })
    vim.env.FAKE_GH_DELAY = "1"
    vim.fn.chdir(dir)

    local bufs = edit({ "a.txt" })
    assert.is_true(await(bufs, review.merge_base(dir), 5000))
    toggle()
    assert.is_true(await(bufs, nil, 5000))

    assert.is_false(vim.wait(1500, function()
      return revision(bufs[1]) ~= nil
    end, 20))
  end)

  it("leaves a base set by hand alone while the mode toggles", function()
    review.fixture(dir, "toggled", { "a.txt", "b.txt" })
    local tip = support.git({ "rev-parse", "HEAD" }, dir)
    vim.fn.chdir(dir)
    local bufs = edit({ "a.txt", "b.txt" })
    local base = review.merge_base(dir)
    assert.is_true(await(bufs, base, 5000))
    vim.api.nvim_buf_call(bufs[1], function()
      require("gitsigns").change_base(tip)
    end)
    assert.is_true(await({ bufs[1] }, tip, 5000))

    toggle()
    assert.is_true(await({ bufs[2] }, nil, 5000))
    toggle()
    assert.is_true(await({ bufs[2] }, base, 5000))

    assert.is_true(settle())
    assert.equal(tip, revision(bufs[1]))
  end)
end)
