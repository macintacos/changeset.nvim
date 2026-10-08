local Git = require("changeset.git")
local Fixture = require("support.git")

describe("changeset.git", function()
  local tmp, previous_dir

  -- Every assertion here calls `Git` with no cwd, so the fixture repo has to be
  -- the process cwd rather than merely a directory git is pointed at.
  before_each(function()
    tmp, previous_dir = Fixture.enter_tempdir()
  end)

  after_each(function()
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
  end)

  describe("default_base", function()
    it("picks the conventional branch that exists", function()
      Fixture.init_repo("trunk", tmp)
      assert.equal("trunk", Git.default_base())
    end)

    it("prefers origin/HEAD over the conventional names", function()
      Fixture.init_repo("main", tmp)
      Fixture.git({ "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/mainline" }, tmp)
      assert.equal("mainline", Git.default_base())
    end)

    it("finds a conventional branch that only origin has", function()
      Fixture.init_repo("master", tmp)
      Fixture.git({ "update-ref", "refs/remotes/origin/master", "HEAD" }, tmp)
      Fixture.git({ "checkout", "-q", "-b", "feature" }, tmp)
      Fixture.git({ "branch", "-q", "-D", "master" }, tmp)
      assert.equal("master", Git.default_base())
    end)

    it("falls back to main when nothing matches", function()
      Fixture.init_repo("weird", tmp)
      assert.equal("main", Git.default_base())
    end)
  end)

  describe("merge_base", function()
    it("returns the commit HEAD forked from", function()
      local fork = Fixture.init_repo("trunk", tmp)
      Fixture.git({ "checkout", "-q", "-b", "feature" }, tmp)
      Fixture.git({ "commit", "-q", "--allow-empty", "-m", "work" }, tmp)

      assert.equal(fork, (Git.merge_base(nil, "trunk")))
    end)

    it("names the remote ref it measured against when one exists", function()
      local fork = Fixture.init_repo("trunk", tmp)
      Fixture.git({ "update-ref", "refs/remotes/origin/trunk", fork }, tmp)
      Fixture.git({ "checkout", "-q", "-b", "feature" }, tmp)

      local _, ref = Git.merge_base(nil, "trunk")
      assert.equal("origin/trunk", ref)
    end)

    it("names the local branch when there is no remote to measure against", function()
      Fixture.init_repo("trunk", tmp)
      Fixture.git({ "checkout", "-q", "-b", "feature" }, tmp)

      local _, ref = Git.merge_base(nil, "trunk")
      assert.equal("trunk", ref)
    end)

    it("measures the repo it is given rather than the one Neovim sits in", function()
      local fork = Fixture.init_repo("trunk", tmp)
      Fixture.git({ "checkout", "-q", "-b", "feature" }, tmp)
      vim.fn.chdir(previous_dir)

      assert.equal(fork, (Git.merge_base(tmp, "trunk")))
    end)

    it("returns nil outside a repo", function()
      assert.is_nil(Git.merge_base(nil, "main"))
    end)

    it("measures against the branch it is given", function()
      Fixture.init_repo("trunk", tmp)
      Fixture.git({ "checkout", "-q", "-b", "parent" }, tmp)
      Fixture.git({ "commit", "-q", "--allow-empty", "-m", "parent work" }, tmp)
      local parent = Fixture.git({ "rev-parse", "HEAD" }, tmp)
      Fixture.git({ "checkout", "-q", "-b", "child" }, tmp)
      Fixture.git({ "commit", "-q", "--allow-empty", "-m", "child work" }, tmp)

      assert.equal(parent, (Git.merge_base(nil, "parent")))
    end)

    it("takes an unpushed local branch's newer fork point", function()
      Fixture.init_repo("trunk", tmp)
      Fixture.git({ "checkout", "-q", "-b", "parent" }, tmp)
      Fixture.git({ "commit", "-q", "--allow-empty", "-m", "p1" }, tmp)
      Fixture.git({ "update-ref", "refs/remotes/origin/parent", "HEAD" }, tmp)
      Fixture.git({ "commit", "-q", "--allow-empty", "-m", "p2" }, tmp)
      local p2 = Fixture.git({ "rev-parse", "HEAD" }, tmp)
      Fixture.git({ "checkout", "-q", "-b", "child" }, tmp)
      Fixture.git({ "commit", "-q", "--allow-empty", "-m", "child work" }, tmp)

      local sha, ref = Git.merge_base(nil, "parent")
      assert.equal(p2, sha)
      assert.equal("parent", ref)
    end)

    it("keeps the remote's newer fork point over a stale local branch", function()
      local t1 = Fixture.init_repo("trunk", tmp)
      Fixture.git({ "commit", "-q", "--allow-empty", "-m", "t2" }, tmp)
      local t2 = Fixture.git({ "rev-parse", "HEAD" }, tmp)
      Fixture.git({ "update-ref", "refs/remotes/origin/trunk", t2 }, tmp)
      Fixture.git({ "checkout", "-q", "-b", "feature" }, tmp)
      Fixture.git({ "branch", "-f", "trunk", t1 }, tmp)

      local sha, ref = Git.merge_base(nil, "trunk")
      assert.equal(t2, sha)
      assert.equal("origin/trunk", ref)
    end)

    it("returns nil for a branch that does not exist", function()
      Fixture.init_repo("trunk", tmp)
      assert.is_nil(Git.merge_base(nil, "missing"))
    end)
  end)

  describe("parent", function()
    local root_commit

    before_each(function()
      root_commit = Fixture.init_repo("trunk", tmp)
      Fixture.git({ "switch", "-q", "-c", "parent" }, tmp)
      Fixture.git({ "commit", "-q", "--allow-empty", "-m", "parent work" }, tmp)
      Fixture.git({ "update-ref", "refs/remotes/origin/parent", "parent" }, tmp)
      Fixture.git({ "update-ref", "refs/remotes/origin/feature", "parent" }, tmp)
    end)

    it("names the local branch a branch was created from", function()
      Fixture.git({ "switch", "-q", "-c", "feature", "parent" }, tmp)

      assert.equal("parent", Git.parent(tmp, "feature"))
    end)

    it("names the branch behind a remote ref a branch was created from", function()
      Fixture.git({ "switch", "-q", "-c", "feature", "origin/parent" }, tmp)

      assert.equal("parent", Git.parent(tmp, "feature"))
    end)

    it("reads the repository it is given rather than the one Neovim sits in", function()
      Fixture.git({ "switch", "-q", "-c", "feature", "parent" }, tmp)
      vim.fn.chdir(previous_dir)

      assert.equal("parent", Git.parent(tmp, "feature"))
    end)

    for _, created in ipairs({
      { "its own remote counterpart, named short", { "switch", "-q", "-c", "feature", "origin/feature" } },
      { "its own remote counterpart, named in full", { "branch", "feature", "refs/remotes/origin/feature" } },
    }) do
      it("is nil for a branch created from " .. created[1], function()
        Fixture.git(created[2], tmp)

        assert.is_nil(Git.parent(tmp, "feature"))
      end)
    end

    for _, command in ipairs({
      { "switch", "-q", "-c", "feature" },
      { "checkout", "-q", "-b", "feature" },
    }) do
      it(("names the branch `git %s %s` was run on"):format(command[1], command[3]), function()
        Fixture.git(command, tmp)

        assert.equal("parent", Git.parent(tmp, "feature"))
      end)
    end

    it("names the branch HEAD was on when it created the branch, not one it came back from", function()
      Fixture.git({ "switch", "-q", "-c", "feature" }, tmp)
      Fixture.git({ "switch", "-q", "-c", "other" }, tmp)
      Fixture.git({ "switch", "-q", "feature" }, tmp)

      assert.equal("parent", Git.parent(tmp, "feature"))
    end)

    it("names the branch HEAD was on when it created the branch, not an earlier branch of that name", function()
      Fixture.git({ "switch", "-q", "-c", "feature" }, tmp)
      Fixture.git({ "switch", "-q", "trunk" }, tmp)
      Fixture.git({ "branch", "-q", "-D", "feature" }, tmp)
      Fixture.git({ "switch", "-q", "-c", "feature" }, tmp)

      assert.equal("trunk", Git.parent(tmp, "feature"))
    end)

    it("is nil for a branch created from a detached HEAD", function()
      Fixture.git({ "switch", "-q", "--detach" }, tmp)
      Fixture.git({ "switch", "-q", "-c", "feature" }, tmp)

      assert.is_nil(Git.parent(tmp, "feature"))
    end)

    it("is nil for a branch created from HEAD in another worktree", function()
      Fixture.git({ "worktree", "add", "-q", "-b", "feature", tmp .. "/wt" }, tmp)

      assert.is_nil(Git.parent(tmp .. "/wt", "feature"))
      assert.is_nil(Git.parent(tmp, "feature"))
    end)

    it("is nil for a branch created from a commit", function()
      Fixture.git({ "switch", "-q", "-c", "feature", root_commit }, tmp)

      assert.is_nil(Git.parent(tmp, "feature"))
    end)

    it("is nil once the branch it was created from is deleted", function()
      Fixture.git({ "switch", "-q", "-c", "feature", "parent" }, tmp)
      Fixture.git({ "branch", "-q", "-D", "parent" }, tmp)

      assert.is_nil(Git.parent(tmp, "feature"))
    end)

    it("is nil for a branch whose reflog is gone", function()
      Fixture.git({ "switch", "-q", "-c", "feature", "parent" }, tmp)
      vim.fn.delete(tmp .. "/.git/logs/refs/heads/feature")

      assert.is_nil(Git.parent(tmp, "feature"))
    end)
  end)
  describe("async", function()
    ---Run `fn` through `Git.async`, waiting for what it returns.
    ---@param fn fun(): any
    ---@return any
    local function run(fn)
      local done, result = false, nil
      Git.async(fn, function(value)
        done, result = true, value
      end)
      assert.is_true(vim.wait(5000, function()
        return done
      end, 10))
      return result
    end

    before_each(function()
      Fixture.init_repo("main", tmp)
    end)

    it("reads a failed command's lines as none", function()
      assert.same(
        {},
        run(function()
          return Git.lines({ "git", "rev-parse", "--verify", "no-such-ref" }, tmp)
        end)
      )
    end)

    it("keeps the last line of output that ends without a newline", function()
      local fd = assert(io.open(tmp .. "/blob", "w"))
      fd:write("one\ntwo")
      fd:close()
      local oid = Fixture.git({ "hash-object", "-w", "blob" }, tmp)

      assert.same(
        { "one", "two" },
        run(function()
          return Git.lines({ "git", "cat-file", "blob", oid }, tmp)
        end)
      )
    end)

    it("tells an ancestor from a commit that is not one", function()
      local first = Fixture.git({ "rev-parse", "HEAD" }, tmp)
      vim.fn.writefile({ "more" }, tmp .. "/more.txt")
      local second = Fixture.commit("more", tmp)

      assert.same(
        { true, false },
        run(function()
          return { Git.is_ancestor(tmp, first, second), Git.is_ancestor(tmp, second, first) }
        end)
      )
    end)

    it("raises an error raised inside fn, with its traceback", function()
      local ok, err = pcall(Git.async, function()
        error("measure failed")
      end, function() end)

      assert.is_false(ok)
      assert.matches("measure failed.*stack traceback", err)
    end)
  end)

  describe("system", function()
    it("hands a failed spawn to on_exit on the main loop as a failed result", function()
      local real = vim.system
      vim.system = function()
        error("E2BIG")
      end
      local got, fast
      Git.system({ "git", "status" }, {}, function(result)
        got, fast = result, vim.in_fast_event()
      end)
      vim.system = real
      assert.is_nil(got)
      vim.wait(1000, function()
        return got ~= nil
      end)
      assert.equal(-1, got.code)
      assert.matches("E2BIG", got.stderr)
      assert.is_false(fast)
    end)

    it("calls on_exit on the main loop with the process's result", function()
      local got, fast
      Git.system({ "git", "--version" }, { text = true }, function(result)
        got, fast = result, vim.in_fast_event()
      end)
      vim.wait(5000, function()
        return got ~= nil
      end)
      assert.equal(0, got.code)
      assert.matches("^git version", got.stdout)
      assert.is_false(fast)
    end)
  end)

  describe("pr_target", function()
    it("answers no PR when gh can't be started", function()
      require("support.gh")
      local real = vim.system
      vim.system = function()
        error("E2BIG")
      end
      local answered, target = false, "unset"
      local ok = pcall(Git.pr_target, tmp, function(t)
        answered, target = true, t
      end)
      vim.system = real
      assert.is_true(ok)
      vim.wait(1000, function()
        return answered
      end)
      assert.is_nil(target)
    end)
  end)
  describe("head", function()
    local real_systemlist, spawned

    before_each(function()
      spawned = 0
      real_systemlist = vim.fn.systemlist
      vim.fn.systemlist = function(...)
        spawned = spawned + 1
        return real_systemlist(...)
      end
    end)

    after_each(function()
      vim.fn.systemlist = real_systemlist
    end)

    ---What `git rev-parse HEAD --abbrev-ref HEAD` answers at `root`: the branch, then the commit.
    ---@param root string
    local function rev_parse(root)
      local out = real_systemlist({ "git", "-C", root, "rev-parse", "HEAD", "--abbrev-ref", "HEAD" })
      return out[2], out[1]
    end

    it("reads a checked-out branch and its commit without running git", function()
      local commit = Fixture.init_repo("trunk", tmp)
      Fixture.git({ "checkout", "-q", "-b", "feature/x" }, tmp)

      local branch, at = Git.head(tmp)
      assert.same({ "feature/x", commit }, { branch, at })
      assert.equal(0, spawned)
    end)

    it("reads a detached HEAD as HEAD at its commit", function()
      local commit = Fixture.init_repo("trunk", tmp)
      Fixture.git({ "checkout", "-q", "--detach" }, tmp)

      assert.same({ "HEAD", commit }, { Git.head(tmp) })
      assert.equal(0, spawned)
    end)

    it("reads a worktree's branch through its .git file", function()
      Fixture.init_repo("trunk", tmp)
      Fixture.git({ "worktree", "add", "-q", "-b", "feature", tmp .. "/wt" }, tmp)

      assert.same({ rev_parse(tmp .. "/wt") }, { Git.head(tmp .. "/wt") })
      assert.equal(0, spawned)
    end)

    it("reads a stopped rebase as HEAD", function()
      Fixture.init_repo("trunk", tmp)
      Fixture.git({ "commit", "-q", "--allow-empty", "-m", "second" }, tmp)
      vim.fn.system({ "git", "-C", tmp, "rebase", "--exec", "false", "HEAD~1" })
      assert.truthy(vim.uv.fs_stat(tmp .. "/.git/rebase-merge"))

      local branch, commit = Git.head(tmp)
      assert.equal("HEAD", branch)
      assert.equal(select(2, rev_parse(tmp)), commit)
    end)

    it("asks git in a reftable repository", function()
      Fixture.init_repo("trunk", tmp)
      Fixture.git({ "refs", "migrate", "--ref-format=reftable" }, tmp)

      assert.same({ rev_parse(tmp) }, { Git.head(tmp) })
      assert.is_true(spawned > 0)
    end)

    it("asks git for a branch whose ref is packed", function()
      Fixture.init_repo("trunk", tmp)
      Fixture.git({ "pack-refs", "--all" }, tmp)

      assert.same({ rev_parse(tmp) }, { Git.head(tmp) })
      assert.equal("trunk", (Git.head(tmp)))
    end)

    it("answers no branch on an unborn branch, as git does", function()
      Fixture.git({ "init", "-q", "-b", "trunk" }, tmp)

      assert.same({}, { Git.head(tmp) })
    end)

    it("answers nothing outside a repository", function()
      assert.same({}, { Git.head(tmp) })
    end)
  end)

  describe("detached", function()
    local real_systemlist, real_system, spawned

    before_each(function()
      spawned = 0
      real_systemlist, real_system = vim.fn.systemlist, vim.system
      vim.fn.systemlist = function(...)
        spawned = spawned + 1
        return real_systemlist(...)
      end
      vim.system = function(...)
        spawned = spawned + 1
        return real_system(...)
      end
    end)

    after_each(function()
      vim.fn.systemlist, vim.system = real_systemlist, real_system
    end)

    it("is false on a branch", function()
      Fixture.init_repo("trunk", tmp)

      assert.is_false(Git.detached(tmp))
    end)

    it("is true on a detached HEAD, without running git", function()
      Fixture.init_repo("trunk", tmp)
      Fixture.git({ "checkout", "-q", "--detach" }, tmp)
      spawned = 0

      assert.is_true(Git.detached(tmp))
      assert.equal(0, spawned)
    end)

    it("reads a worktree's HEAD through its .git file, without running git", function()
      Fixture.init_repo("trunk", tmp)
      Fixture.git({ "worktree", "add", "-q", "-b", "feature", tmp .. "/wt" }, tmp)
      spawned = 0

      assert.is_false(Git.detached(tmp .. "/wt"))
      assert.equal(0, spawned)
    end)

    it("is false on a branch whose ref is packed, without running git", function()
      Fixture.init_repo("trunk", tmp)
      Fixture.git({ "pack-refs", "--all" }, tmp)
      spawned = 0

      assert.is_false(Git.detached(tmp))
      assert.equal(0, spawned)
    end)
  end)
end)
