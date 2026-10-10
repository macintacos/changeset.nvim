local gh = require("support.gh")
local support = require("support.git")
local gutter = require("support.gutter")
local Notify = require("support.notify")

local await, edit, revision = gutter.await, gutter.edit, gutter.revision

describe("the gutter's base", function()
  local dir, cwd, restore_notify, change_base
  ---@type { msg: string, level: integer? }[]
  local notices

  ---A repo with `a.txt` changed on `parent`, then again on `child` cut from it.
  ---@param child string
  ---@param source string? What `child`'s reflog says it was created from: parent's tip commit, which names no
  ---parent, when absent.
  local function stack(child, source)
    gutter.fixture(dir, "parent", { "a.txt" })
    support.git({ "switch", "-q", "-c", child, source or support.git({ "rev-parse", "HEAD" }, dir) }, dir)
    vim.fn.writefile({ "one", "two", "three" }, dir .. "/a.txt")
    support.commit("child change", dir)
  end

  before_each(function()
    cwd = vim.fn.getcwd()
    dir = gutter.repo()
    notices, restore_notify = Notify.capture()
    change_base = require("gitsigns").change_base
  end)

  after_each(function()
    gutter.teardown(dir, cwd)
    vim.env.FAKE_GH_PR = nil
    vim.env.FAKE_GH_DELAY = nil
    restore_notify()
    require("gitsigns").change_base = change_base
  end)

  ---Waits for a notice at `level` whose text contains `text`.
  ---@param level integer
  ---@param text string
  ---@return string? msg nil when none came within five seconds.
  local function notice(level, text)
    local found
    vim.wait(5000, function()
      found = vim.iter(notices):find(function(n)
        return n.level == level and n.msg:find(text, 1, true) ~= nil
      end)
      return found ~= nil
    end, 20)
    return found and found.msg
  end

  it("diffs a stacked branch against its PR's target branch", function()
    stack("stacked")
    vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "parent" })
    vim.fn.chdir(dir)

    local bufs = edit({ "a.txt" })

    assert.is_true(await(bufs, gutter.merge_base(dir, "parent"), 5000))
  end)

  it("diffs a branch against the one it was created from", function()
    stack("created-from-parent", "parent")
    vim.fn.chdir(dir)

    local bufs = edit({ "a.txt" })

    assert.is_true(await(bufs, gutter.merge_base(dir, "parent"), 5000))
  end)

  it("warns, and diffs against the default branch, when the PR target has no merge base", function()
    gutter.fixture(dir, "orphan-target", { "a.txt" })
    vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "gone" })
    vim.fn.chdir(dir)
    local bufs = edit({ "a.txt" })

    assert.is_true(await(bufs, gutter.merge_base(dir), 5000))
    local msg = notice(vim.log.levels.WARN, "gone")
    assert.not_nil(msg)
    assert.matches("^Changeset: ", msg)
  end)

  it("reports a base change that fails as an error", function()
    gutter.fixture(dir, "change-failed", { "a.txt" })
    require("gitsigns").change_base = function(_, _, cb)
      vim.schedule(function()
        cb("boom")
      end)
    end
    vim.fn.chdir(dir)

    edit({ "a.txt" })

    assert.not_nil(notice(vim.log.levels.ERROR, "boom"))
  end)

  it("diffs against the default-branch base when gh is not installed", function()
    gutter.fixture(dir, "no-gh", { "a.txt" })
    vim.fn.chdir(dir)
    local base = gutter.merge_base(dir)

    gh.without(function()
      local bufs = edit({ "a.txt" })
      assert.is_true(await(bufs, base, 5000))
    end)
  end)

  it("diffs the default branch against its remote, so its unpushed commits show", function()
    vim.fn.writefile({ "one" }, dir .. "/a.txt")
    local pushed = support.commit("pushed", dir)
    support.git({ "update-ref", "refs/remotes/origin/main", pushed }, dir)
    vim.fn.writefile({ "one", "two" }, dir .. "/a.txt")
    support.commit("unpushed", dir)
    vim.fn.chdir(dir)

    local bufs = edit({ "a.txt" })

    assert.is_true(await(bufs, pushed, 5000))
  end)

  it("falls back to the index, without a warning, when the default branch shares no history with its remote", function()
    local empty_tree = support.git({ "hash-object", "-t", "tree", "/dev/null" }, dir)
    local unrelated = support.git({ "commit-tree", empty_tree, "-m", "unrelated" }, dir)
    support.git({ "update-ref", "refs/remotes/origin/main", unrelated }, dir)
    vim.fn.writefile({ "one", "two" }, dir .. "/a.txt")
    vim.fn.chdir(dir)

    local bufs = edit({ "a.txt" })
    assert.is_true(vim.wait(5000, function()
      return vim.b[bufs[1]].gitsigns_status_dict ~= nil
    end, 20))
    assert.is_false(vim.wait(1000, function()
      return #Notify.messages(notices, vim.log.levels.WARN) > 0
    end, 20))

    assert.is_nil(revision(bufs[1]))
  end)

  it("drops a PR lookup that a branch switch superseded", function()
    stack("stacked-switched")
    vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "parent" })
    vim.env.FAKE_GH_DELAY = "1"
    vim.fn.chdir(dir)
    local bufs = edit({ "a.txt" })
    assert.is_true(await(bufs, gutter.merge_base(dir), 5000))
    local parent_tip = support.git({ "rev-parse", "parent" }, dir)

    -- The child's lookup is still in flight when the switch happens. Its answer names the parent, and must
    -- not move main's buffers onto it.
    vim.env.FAKE_GH_PR = nil
    support.git({ "switch", "-q", "main" }, dir)
    assert.is_true(vim.wait(10000, function()
      return vim.b[bufs[1]].gitsigns_head == "main"
    end, 20))

    assert.is_false(vim.wait(1500, function()
      return revision(bufs[1]) == parent_tip
    end, 20))
  end)
end)
