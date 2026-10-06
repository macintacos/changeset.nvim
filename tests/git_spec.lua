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
end)
