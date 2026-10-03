local gh = require("support.gh")
local Pending = require("changeset.pending_review")

local SANDBOX = "https://github.com/macintacos/changeset-nvim-review-sandbox/pull/1"
local REVIEW = "PRR_kwDOU6Rmbc8AAAABQfBqzA"

---Call `Pending[name]` without letting it raise, and wait for its callback.
---@param name string
---@return string? err
---@return any value
local function run(name, ...)
  local done, err, value = false, nil, nil
  local args = vim.F.pack_len(...)
  args[args.n + 1] = function(e, v)
    done, err, value = true, e, v
  end
  assert.is_true(pcall(Pending[name], unpack(args, 1, args.n + 1)))
  assert.is_false(done)
  assert.is_true(vim.wait(5000, function()
    return done
  end))
  return err, value
end

---@param args string[]
---@param prefix string
---@return boolean
local function has_prefix(args, prefix)
  return vim.iter(args):any(function(a)
    return vim.startswith(a, prefix)
  end)
end

---@param args string[]
---@param prefix string
---@return string?
local function arg(args, prefix)
  return vim.iter(args):find(function(a)
    return vim.startswith(a, prefix)
  end)
end

describe("pending_review", function()
  after_each(gh.reset)

  describe("find", function()
    it("returns the pending review with every review comment", function()
      gh.answer({ stdout = gh.pr_view({ url = SANDBOX }) })
      gh.fixture("find-pending-review")
      gh.fixture("review-comments-paginate-slurp")

      local err, found = run("find", nil)

      assert.is_nil(err)
      assert.equal(REVIEW, found.review.id)
      assert.equal(6, #found.review.comments)
      assert.same({
        id = "PRRC_kwDOU6Rmbc74w1hf",
        path = "alpha.txt",
        line = 10,
        start_line = 8,
        body = "Range over changed and unchanged lines, inside one hunk",
      }, found.review.comments[3])
      assert.is_nil(found.review.comments[1].start_line)
      assert.is_nil(found.review.comments[6].line)
      assert.equal("PR_kwDOU6Rmbc8AAAABGcSBYA", found.pr.id)
      assert.is_true(found.pr.viewer_did_author)
      local calls = gh.calls()
      assert.is_true(vim.list_contains(calls[2], "owner=macintacos"))
      assert.is_true(vim.list_contains(calls[2], "name=changeset-nvim-review-sandbox"))
      assert.is_true(vim.list_contains(calls[2], "number=1"))
      assert.is_true(vim.list_contains(calls[3], "--paginate"))
      assert.is_true(vim.list_contains(calls[3], "--slurp"))
      assert.is_true(vim.list_contains(calls[3], "review=" .. REVIEW))
    end)

    it("asks the PR's own host", function()
      gh.answer({ stdout = gh.pr_view({ url = "https://ghe.example.com/owner/repo/pull/3" }) })
      gh.fixture("find-pending-review")
      gh.fixture("review-comments-paginate-slurp")

      run("find", nil)

      for _, call in ipairs({ unpack(gh.calls(), 2, 3) }) do
        local at = assert(vim.iter(ipairs(call)):find(function(_, a)
          return a == "--hostname"
        end))
        assert.equal("ghe.example.com", call[at + 1])
      end
    end)

    it("serves queued answers to the calls after them", function()
      run("delete", REVIEW)
      gh.answer({ stdout = gh.pr_view({ url = SANDBOX }) })
      gh.fixture("find-pending-review-empty")

      local err, found = run("find", nil)

      assert.is_nil(err)
      assert.equal("PR_kwDOU6Rmbc8AAAABGcSBYA", found.pr.id)
    end)

    it("returns no review when the viewer has none", function()
      gh.answer({ stdout = gh.pr_view({ url = SANDBOX }) })
      gh.fixture("find-pending-review-empty")

      local err, found = run("find", nil)

      assert.is_nil(err)
      assert.is_nil(found.review)
      assert.equal(2, #gh.calls())
    end)

    it("finds a pending review another client started", function()
      gh.answer({ stdout = gh.pr_view({ url = SANDBOX }) })
      gh.fixture("find-pending-review-rest-created")
      gh.fixture("review-comments-paginate-slurp")

      local _, found = run("find", nil)

      assert.equal("PRR_kwDOU6Rmbc8AAAABQfCQkw", found.review.id)
    end)
  end)

  describe("start", function()
    it("starts an empty pending review", function()
      gh.fixture("add-pending-review")

      local err, review = run("start", "PR_1")

      assert.is_nil(err)
      assert.same({ id = REVIEW, comments = {} }, review)
      assert.is_true(vim.list_contains(gh.calls()[1], "pr=PR_1"))
    end)

    it("passes on GitHub's refusal", function()
      gh.fixture("second-add-pending-review")

      assert.matches("User can only have one pending review per pull request", (run("start", "PR_1")))
    end)
  end)

  describe("add_comment", function()
    it("adds a review comment on one line", function()
      gh.fixture("add-thread-added-line")

      local err, comment = run("add_comment", REVIEW, { path = "alpha.txt", line = 31, body = "hi" })

      assert.is_nil(err)
      assert.equal("PRRC_kwDOU6Rmbc74w1gA", comment.id)
      assert.equal(31, comment.line)
      assert.is_nil(comment.start_line)
      assert.is_false(has_prefix(gh.calls()[1], "startLine="))
    end)

    it("adds a review comment on a range", function()
      gh.fixture("add-thread-range-in-hunk")

      local _, comment = run("add_comment", REVIEW, { path = "alpha.txt", start_line = 8, line = 10, body = "hi" })

      assert.equal(8, comment.start_line)
      assert.equal(10, comment.line)
      assert.is_true(vim.list_contains(gh.calls()[1], "startLine=8"))
      assert.is_true(vim.list_contains(gh.calls()[1], "line=10"))
    end)

    it("fails when GitHub silently refuses the lines", function()
      gh.fixture("add-thread-outside-hunk")

      local err = run("add_comment", REVIEW, { path = "alpha.txt", line = 20, body = "hi" })

      assert.matches("alpha.txt", err)
    end)

    it("sends the body verbatim", function()
      local body = "q\"uote 'single' $(echo hi) `tick`\nsecond line"
      gh.fixture("add-thread-added-line")
      gh.fixture("add-thread-added-line")

      run("add_comment", REVIEW, { path = "alpha.txt", line = 31, body = body })
      run("add_comment", REVIEW, { path = "alpha.txt", line = 31, body = "plain" })

      local calls = gh.calls()
      assert.is_true(vim.list_contains(calls[1], "body=" .. body))
      assert.equal(arg(calls[2], "query="), arg(calls[1], "query="))
    end)
  end)

  it("deletes a review comment", function()
    gh.fixture("delete-review-comment")

    assert.is_nil((run("delete_comment", "PRRC_1")))
    assert.is_true(vim.list_contains(gh.calls()[1], "id=PRRC_1"))
  end)

  it("deletes the pending review", function()
    gh.fixture("delete-pending-review")

    assert.is_nil((run("delete", REVIEW)))
    assert.is_true(vim.list_contains(gh.calls()[1], "review=" .. REVIEW))
  end)

  describe("submit", function()
    it("submits with a body", function()
      gh.fixture("submit-comment-with-body")

      assert.is_nil((run("submit", REVIEW, { event = "COMMENT", body = "done" })))
      assert.is_true(vim.list_contains(gh.calls()[1], "event=COMMENT"))
      assert.is_true(vim.list_contains(gh.calls()[1], "body=done"))
    end)

    it("submits without a body", function()
      gh.fixture("submit-comment-one-review-comment-no-body")

      assert.is_nil((run("submit", REVIEW, { event = "COMMENT" })))
      assert.is_false(has_prefix(gh.calls()[1], "body="))
    end)

    it("passes on GitHub's refusal", function()
      gh.fixture("submit-approve")

      assert.matches(
        "Could not approve for pull request review. Can not approve your own pull request",
        (run("submit", REVIEW, { event = "APPROVE" }))
      )
    end)
  end)

  describe("failures", function()
    local cases = {
      ["gh isn't installed"] = function(fn)
        return gh.without(fn)
      end,
      ["gh isn't authenticated"] = function(fn)
        gh.answer({ code = 4, stderr = "To get started with GitHub CLI, please run:  gh auth login\n" })
        return fn()
      end,
      ["the PR isn't open"] = function(fn)
        gh.answer({ stdout = gh.pr_view({ url = SANDBOX, state = "MERGED" }) })
        return fn()
      end,
    }
    for name, setup in pairs(cases) do
      it("reach find when " .. name, function()
        assert.is_string((setup(function()
          return run("find", nil)
        end)))
      end)

      if name ~= "the PR isn't open" then
        it("reach a mutation when " .. name, function()
          assert.is_string((setup(function()
            return run("delete", REVIEW)
          end)))
        end)
      end
    end
  end)
end)
