local Git = require("changeset.git")
local Fixture = require("support.git")
local gh = require("support.gh")

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

  describe("pr", function()
    after_each(gh.reset)

    ---Call `Git.pr` without letting it raise, and wait for its callback.
    ---@param cwd string?
    ---@return string? err
    ---@return changeset.Pr? pr
    local function ask(cwd)
      local done, err, pr = false, nil, nil
      assert.is_true(pcall(Git.pr, cwd, function(e, p)
        done, err, pr = true, e, p
      end))
      assert.is_false(done)
      assert.is_true(vim.wait(5000, function()
        return done
      end))
      return err, pr
    end

    it("yields the open PR and the repository it was opened against", function()
      gh.answer({
        stdout = gh.pr_view({
          baseRefName = "trunk",
          number = 7,
          url = "https://github.com/owner/repo/pull/7",
          headRefOid = "abc",
          author = { login = "dev" },
        }),
      })

      local err, pr = ask()

      assert.is_nil(err)
      assert.same({ target = "trunk", number = 7, owner = "owner", name = "repo", head = "abc", author = "dev" }, pr)
      assert.same({ { "pr", "view", "--json", "author,baseRefName,headRefOid,number,state,url" } }, gh.calls())
    end)

    it("names the upstream repository from a fork checkout", function()
      gh.answer({
        stdout = gh.pr_view({
          baseRefName = "main",
          url = "https://github.com/upstream/project/pull/1",
          author = { login = "forker" },
        }),
      })

      local _, pr = ask()

      assert(pr)
      assert.equal("upstream", pr.owner)
      assert.equal("project", pr.name)
      assert.equal("forker", pr.author)
    end)

    it("refuses a PR that isn't open", function()
      gh.answer({ stdout = gh.pr_view({ baseRefName = "main", number = 9, state = "MERGED" }) })

      local err, pr = ask()

      assert.is_nil(pr)
      assert.matches("#9", err)
      assert.matches("MERGED", err)
    end)

    it("passes on gh's reason when the branch has no PR", function()
      gh.answer({ code = 1, stderr = 'no pull requests found for branch "feature"\n' })

      assert.equal('no pull requests found for branch "feature"', (ask()))
    end)

    it("passes on gh's reason when it isn't authenticated", function()
      gh.answer({ code = 4, stderr = "To get started with GitHub CLI, please run:  gh auth login\n" })

      assert.matches("gh auth login", ask())
    end)

    it("says so when gh isn't installed", function()
      local err = gh.without(ask)

      assert.matches("`gh` not found", err)
    end)

    it("refuses a url that names no repository", function()
      gh.answer({
        stdout = '{"baseRefName":"main","number":1,"state":"OPEN","headRefOid":"abc","author":{"login":"a"}}',
      })
      gh.answer({ stdout = gh.pr_view({ baseRefName = "main", url = "https://example.com/nope" }) })

      assert.is_string((ask()))
      assert.is_string((ask()))
    end)

    it("fails on output that isn't JSON", function()
      gh.answer({ stdout = "not json" })

      assert.is_string((ask()))
    end)

    it("fails on a GraphQL error even when gh exits 0", function()
      gh.answer({ stdout = '{"data":null,"errors":[{"message":"boom"}]}' })

      assert.matches("boom", ask())
    end)

    it("fails when the directory doesn't exist", function()
      assert.is_string((ask(tmp .. "/missing")))
    end)
  end)
end)
