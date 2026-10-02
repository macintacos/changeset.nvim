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
end)
