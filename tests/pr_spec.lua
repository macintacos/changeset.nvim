local Fixture = require("support.git")

local STUBBED = {
  "changeset.pending_state",
  "changeset.pending_review",
  "changeset.build",
  "changeset.pr",
  "changeset.window",
  "changeset.review_comments",
  "changeset.review_comment_window",
  "changeset.submit_window",
  "changeset.confirm",
}

describe("changeset.pr", function()
  local notify, notes, prompts, fetched, started, deleted, deleted_comments, added, opened, previews, submitted
  ---@type { id: string, body: string }[] Each review comment `update_comment` was asked to change.
  local updated
  ---@type { [1]: string, [2]: boolean }[] Each wait on gh or on the user, and whether progress showed meanwhile.
  local waits
  ---@type { id: integer|string, status: string }[] Every progress message changeset emitted, in order.
  local progress
  ---@type table? What `pending_state.get` answers.
  local held
  ---@type { err: string?, found: table? }[] What each fetch answers, in order; the last repeats.
  local answers
  ---@type boolean Whether the user confirms a question.
  local confirmed
  ---@type string? What the client's `start`, `delete` or `add_comment` fails with.
  local failure
  local tree

  local drafts = require("changeset.drafts")
  local HEAD = "abcdef0123456789abcdef0123456789abcdef01"
  local pr = { id = "PR_1", number = 412, host = "github.com", owner = "acme", name = "widgets", head = HEAD }

  ---How many progress messages are still running.
  ---@return integer
  local function running()
    local last = {}
    for _, event in ipairs(progress) do
      last[event.id] = event.status
    end
    return #vim.tbl_filter(function(status)
      return status == "running"
    end, vim.tbl_values(last))
  end

  ---@param what string
  local function wait(what)
    table.insert(waits, { what, running() > 0 })
  end

  before_each(function()
    os.remove(drafts.path())
    notes, prompts, fetched, started, deleted, deleted_comments, added, opened, previews, submitted =
      {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
    waits, progress, updated = {}, {}, {}
    -- Fires: changeset emitting or updating a progress message.
    vim.api.nvim_create_autocmd("Progress", {
      group = vim.api.nvim_create_augroup("pr_spec.progress", { clear = true }),
      pattern = "changeset",
      callback = function(ev)
        table.insert(progress, { id = ev.data.id, status = ev.data.status })
      end,
    })
    held = nil
    answers, confirmed, failure = {}, false, nil
    tree = { root = "/tree/root", pr = 412 }
    notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notes, { msg = msg, level = level })
    end
    package.loaded["changeset.confirm"] = {
      ask = function(question, yes)
        wait("ask")
        table.insert(prompts, question)
        if confirmed then
          yes()
        end
      end,
    }
    package.loaded["changeset.pending_state"] = {
      subscribe = function() end,
      fetch = function(root, cb)
        wait("fetch")
        table.insert(fetched, root)
        local answer = answers[math.min(#fetched, #answers)] or {}
        held = answer.found or held
        if cb then
          cb(answer.err, answer.found)
        end
      end,
      get = function()
        return held
      end,
    }
    package.loaded["changeset.pending_review"] = {
      start = function(id, cb)
        wait("start")
        table.insert(started, id)
        cb(failure, not failure and { id = "PRR_NEW", comments = {} } or nil)
      end,
      delete = function(id, cb)
        wait("delete")
        table.insert(deleted, id)
        cb(failure)
      end,
      delete_comment = function(id, cb)
        wait("delete_comment")
        table.insert(deleted_comments, id)
        cb(failure)
      end,
      update_comment = function(id, body, cb)
        wait("update_comment")
        table.insert(updated, { id = id, body = body })
        cb(failure)
      end,
      add_comment = function(id, new, cb)
        wait("add_comment")
        table.insert(added, { id = id, new = new })
        cb(failure)
      end,
      submit = function(id, submission, cb)
        wait("submit")
        table.insert(submitted, { id = id, submission = submission })
        cb(failure)
      end,
    }
    package.loaded["changeset.submit_window"] = {
      open = function(opts)
        wait("preview")
        table.insert(previews, opts)
      end,
    }
    package.loaded["changeset.review_comment_window"] = {
      open = function(opts)
        table.insert(opened, opts)
      end,
    }
    package.loaded["changeset.build"] = {
      current = function()
        return tree
      end,
      subscribe = function() end,
    }
    package.loaded["changeset.pr"] = nil
  end)

  after_each(function()
    vim.notify = notify
    for _, name in ipairs(STUBBED) do
      package.loaded[name] = nil
    end
  end)

  local function levels()
    return vim.tbl_map(function(note)
      return note.level
    end, notes)
  end

  describe("progress", function()
    it("shows while GitHub is asked for the PR, and ends when it can't answer", function()
      answers = { { err = "no open PR" } }

      require("changeset.pr").start()

      assert.same({ { "fetch", true } }, waits)
      assert.equal("failed", progress[#progress].status)
      assert.equal(0, running())
    end)

    it("ends when the verb asks GitHub nothing more", function()
      answers = { { found = { pr = pr, review = { id = "R", comments = {} } } } }

      require("changeset.pr").start()

      assert.same({ { "fetch", true } }, waits)
      assert.equal(0, running())
    end)

    it("shows while GitHub changes the review, then ends before the header refetches", function()
      answers = { { found = { pr = pr } } }

      require("changeset.pr").start()

      assert.same({ { "fetch", true }, { "start", true }, { "fetch", false } }, waits)
      assert.equal("success", progress[#progress].status)
    end)

    it("ends failed when GitHub refuses the change", function()
      answers, failure = { { found = { pr = pr } } }, "network down"

      require("changeset.pr").start()

      assert.equal("failed", progress[#progress].status)
      assert.equal(0, running())
    end)

    it("is gone while the user is asked, and back while GitHub abandons the review", function()
      answers, confirmed = { { found = { pr = pr, review = { id = "R", comments = {} } } } }, true

      require("changeset.pr").abandon()

      assert.same({ { "fetch", true }, { "ask", false }, { "delete", true }, { "fetch", false } }, waits)
    end)

    it("is gone while the submit preview is open, and back while GitHub submits", function()
      local review = { id = "R", comments = { { id = "C", path = "a.lua", line = 1, body = "x", outdated = false } } }
      answers = { { found = { pr = pr, review = review } } }
      require("changeset.pr").submit()

      previews[1].submit({ event = "COMMENT" }, function() end)

      assert.same({ { "fetch", true }, { "preview", false }, { "submit", true }, { "fetch", false } }, waits)
    end)
  end)

  describe("start", function()
    it("warns with gh's text when there is no PR", function()
      answers = { { err = 'no pull requests found for branch "x"' } }

      require("changeset.pr").start()

      assert.same({ vim.log.levels.WARN }, levels())
      assert.truthy(notes[1].msg:find('no pull requests found for branch "x"', 1, true))
      assert.same({}, started)
      assert.equal(1, #fetched)
    end)

    it("says when a pending review is already under way", function()
      answers = { { found = { pr = pr, review = { id = "R", comments = {} } } } }

      require("changeset.pr").start()

      assert.same({ vim.log.levels.INFO }, levels())
      assert.truthy(notes[1].msg:find("under way", 1, true))
      assert.same({}, started)
    end)

    it("starts one on the PR and fetches again", function()
      answers = { { found = { pr = pr } } }

      require("changeset.pr").start()

      assert.same({ "PR_1" }, started)
      assert.same({ vim.log.levels.INFO }, levels())
      assert.equal(2, #fetched)
    end)

    it("reports a failed start and still fetches again", function()
      answers, failure = { { found = { pr = pr } } }, "network down"

      require("changeset.pr").start()

      assert.same({ vim.log.levels.ERROR }, levels())
      assert.truthy(notes[1].msg:find("network down", 1, true))
      assert.equal(2, #fetched)
    end)
  end)

  describe("abandon", function()
    local review = { id = "R_1", comments = { {}, {}, {} } }

    it("says there is nothing to abandon without asking", function()
      answers = { { found = { pr = pr } } }

      require("changeset.pr").abandon()

      assert.same({ vim.log.levels.INFO }, levels())
      assert.same({}, prompts)
      assert.same({}, deleted)
    end)

    it("changes nothing when declined", function()
      answers = { { found = { pr = pr, review = review } } }

      require("changeset.pr").abandon()

      assert.equal(1, #prompts)
      assert.same({}, deleted)
      assert.equal(1, #fetched)
    end)

    it("deletes the review once confirmed, naming the PR and its review comments", function()
      answers, confirmed = { { found = { pr = pr, review = review } } }, true

      require("changeset.pr").abandon()

      assert.truthy(prompts[1]:find("#412", 1, true))
      assert.truthy(prompts[1]:find("3 review comments", 1, true))
      assert.same({ "R_1" }, deleted)
      assert.same({ vim.log.levels.INFO }, levels())
      assert.equal(2, #fetched)
    end)

    it("reports a failed delete and still fetches again", function()
      answers, confirmed, failure = { { found = { pr = pr, review = review } } }, true, "network down"

      require("changeset.pr").abandon()

      assert.same({ vim.log.levels.ERROR }, levels())
      assert.truthy(notes[1].msg:find("network down", 1, true))
      assert.equal(2, #fetched)
    end)

    describe("with drafts", function()
      local other = vim.tbl_extend("force", pr, { number = 413 })
      local old = vim.tbl_extend("force", pr, { head = "0000000" })

      before_each(function()
        drafts.keep(pr, { path = "a.lua", line = 1, head = pr.head, body = "now" })
        drafts.keep(old, { path = "a.lua", line = 2, head = old.head, body = "then" })
        drafts.keep(other, { path = "a.lua", line = 3, head = other.head, body = "elsewhere" })
        answers = { { found = { pr = pr, review = review } } }
      end)

      local function counts()
        return { #drafts.list(pr), #drafts.list(old), #drafts.list(other) }
      end

      it("drops this PR's drafts at every head once the review is deleted", function()
        confirmed = true

        require("changeset.pr").abandon()

        assert.same({ 0, 0, 1 }, counts())
      end)

      it("keeps them when the delete fails", function()
        confirmed, failure = true, "network down"

        require("changeset.pr").abandon()

        assert.same({ 1, 1, 1 }, counts())
      end)

      it("keeps them when declined", function()
        require("changeset.pr").abandon()

        assert.same({ 1, 1, 1 }, counts())
      end)
    end)
  end)

  describe("submit", function()
    local comment = { id = "C1", path = "a.lua", line = 3, body = "fix", outdated = false }
    local review = { id = "R", comments = { comment } }

    ---Submits through the preview `submit` opened, returning what `settled` got.
    ---@param submission table
    ---@return { err: string? }?
    local function confirm(submission)
      local got
      previews[1].submit(submission, function(err)
        got = { err = err }
      end)
      return got
    end

    it("says when there is no pending review", function()
      answers = { { found = { pr = pr } } }

      require("changeset.pr").submit()

      assert.same({ vim.log.levels.INFO }, levels())
      assert.truthy(notes[1].msg:find("no pending review", 1, true))
      assert.same({}, previews)
    end)

    it("hands the window the events GitHub takes on the PR", function()
      answers = { { found = { pr = pr, review = review } } }

      require("changeset.pr").submit()

      assert.same({ "COMMENT", "APPROVE", "REQUEST_CHANGES" }, previews[1].events)
    end)

    it("previews the review's comments and the PR's drafts", function()
      local draft = { path = "a.lua", line = 1, head = pr.head, body = "later" }
      drafts.keep(pr, draft)
      answers = { { found = { pr = pr, review = review } } }

      require("changeset.pr").submit()

      assert.same({ comment }, previews[1].comments)
      assert.same({ draft }, previews[1].drafts)
    end)

    it("submits the review, reports it, fetches again and keeps the drafts", function()
      drafts.keep(pr, { path = "a.lua", line = 1, head = pr.head, body = "later" })
      answers = { { found = { pr = pr, review = review } } }
      require("changeset.pr").submit()

      local settled = confirm({ event = "APPROVE" })

      assert.same({ { id = "R", submission = { event = "APPROVE" } } }, submitted)
      assert.same({ err = nil }, settled)
      assert.same({ vim.log.levels.INFO }, levels())
      assert.truthy(notes[1].msg:find("submitted the pending review on #412", 1, true))
      assert.equal(2, #fetched)
      assert.equal(1, #drafts.list(pr))
    end)

    it("reports GitHub's rejection and fetches again", function()
      answers, failure = { { found = { pr = pr, review = review } } }, "Review cannot be submitted"
      require("changeset.pr").submit()

      local settled = confirm({ event = "COMMENT" })

      assert.same({ err = "Review cannot be submitted" }, settled)
      assert.same({ vim.log.levels.ERROR }, levels())
      assert.truthy(notes[1].msg:find("Review cannot be submitted", 1, true))
      assert.equal(2, #fetched)
    end)

    it("refuses a submit GitHub would refuse without asking it", function()
      answers = { { found = { pr = pr, review = { id = "R", comments = {} } } } }
      require("changeset.pr").submit()

      local reason = assert(confirm({ event = "COMMENT" })).err

      assert.same({ vim.log.levels.WARN }, levels())
      assert.truthy(reason)
      assert.truthy(notes[1].msg:find(reason, 1, true))
      assert.same({}, submitted)
      assert.equal(1, #fetched)
    end)
  end)

  describe("delete", function()
    local dir

    before_each(function()
      dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      dir = vim.fs.normalize(assert(vim.uv.fs_realpath(dir)))
      local lines = {}
      for i = 1, 40 do
        lines[i] = "line " .. i
      end
      vim.fn.writefile(lines, dir .. "/alpha.txt")
      Fixture.init_repo("main", dir)
      vim.cmd.edit(dir .. "/alpha.txt")
    end)

    after_each(function()
      vim.cmd("bwipeout!")
      vim.fn.delete(dir, "rf")
    end)

    ---@param lnum integer
    ---@param comments table[]
    local function delete_on(lnum, comments)
      answers = { { found = { pr = pr, review = { id = "PRR_1", comments = comments } } } }
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
      require("changeset.pr").delete()
    end

    it("deletes the review comment on the cursor's line and fetches again", function()
      delete_on(12, { { id = "C_1", path = "alpha.txt", line = 12, body = "x" } })

      assert.same({ "C_1" }, deleted_comments)
      assert.same({ vim.log.levels.INFO }, levels())
      assert.truthy(notes[1].msg:find("#412", 1, true))
      assert.equal(2, #fetched)
    end)

    it("shows progress while GitHub deletes the review comment", function()
      delete_on(12, { { id = "C_1", path = "alpha.txt", line = 12, body = "x" } })

      assert.same({ { "fetch", true }, { "delete_comment", true }, { "fetch", false } }, waits)
    end)

    it("deletes a range review comment from a line inside it", function()
      delete_on(9, { { id = "C_R", path = "alpha.txt", start_line = 8, line = 10, body = "x" } })

      assert.same({ "C_R" }, deleted_comments)
    end)

    describe("when review comments share a line", function()
      local comments = {
        { id = "C_RANGE", path = "alpha.txt", start_line = 10, line = 31, body = "x" },
        { id = "C_ONE", path = "alpha.txt", line = 31, body = "x" },
      }

      it("deletes the narrowest", function()
        delete_on(31, comments)

        assert.same({ "C_ONE" }, deleted_comments)
      end)

      it("deletes the range from a line only it takes in", function()
        delete_on(20, comments)

        assert.same({ "C_RANGE" }, deleted_comments)
      end)
    end)

    it("ignores another file's review comment on the same line", function()
      delete_on(5, { { id = "C_B", path = "beta.txt", line = 5, body = "x" } })

      assert.same({}, deleted_comments)
      assert.same({ vim.log.levels.INFO }, levels())
      assert.truthy(notes[1].msg:find("no review comment on line 5", 1, true))
      assert.equal(1, #fetched)
    end)

    it("says when the line has no review comment", function()
      delete_on(7, { { id = "C_1", path = "alpha.txt", line = 12, body = "x" } })

      assert.same({}, deleted_comments)
      assert.same({ vim.log.levels.INFO }, levels())
      assert.truthy(notes[1].msg:find("no review comment on line 7", 1, true))
      assert.equal(1, #fetched)
    end)

    it("asks to save a modified buffer first, without asking GitHub", function()
      vim.api.nvim_buf_set_lines(0, 0, 1, false, { "edited" })

      delete_on(12, { { id = "C_1", path = "alpha.txt", line = 12, body = "x" } })

      assert.same({ vim.log.levels.WARN }, levels())
      assert.same({}, fetched)
      assert.same({}, deleted_comments)
    end)

    it("says when there is no pending review", function()
      answers = { { found = { pr = pr } } }

      require("changeset.pr").delete()

      assert.same({ vim.log.levels.INFO }, levels())
      assert.truthy(notes[1].msg:find("no pending review on #412", 1, true))
      assert.same({}, deleted_comments)
    end)

    it("warns with gh's text when there is no PR", function()
      answers = { { err = "no open PR" } }

      require("changeset.pr").delete()

      assert.same({ vim.log.levels.WARN }, levels())
      assert.truthy(notes[1].msg:find("no open PR", 1, true))
      assert.same({}, deleted_comments)
    end)

    it("reports a failed delete and still fetches again", function()
      failure = "boom"

      delete_on(12, { { id = "C_1", path = "alpha.txt", line = 12, body = "x" } })

      assert.same({ vim.log.levels.ERROR }, levels())
      assert.truthy(notes[1].msg:find("boom", 1, true))
      assert.equal(2, #fetched)
    end)

    describe("a draft", function()
      local function keep_draft(overrides)
        drafts.keep(
          pr,
          vim.tbl_extend(
            "force",
            { path = "alpha.txt", start_line = 8, line = 10, head = HEAD, body = "d" },
            overrides or {}
          )
        )
      end

      it("is deleted from a line inside it, without asking GitHub to delete or refetch", function()
        keep_draft()

        delete_on(9, {})

        assert.same({}, drafts.list(pr))
        assert.same({ vim.log.levels.INFO }, levels())
        assert.truthy(notes[1].msg:find("deleted the draft on lines 8-10 of alpha.txt", 1, true))
        assert.same({}, deleted_comments)
        assert.equal(1, #fetched)
      end)

      it("is reported when the record can't be written", function()
        keep_draft()
        vim.fn.setfperm(vim.fs.dirname(drafts.path()), "r-xr-xr-x")

        delete_on(9, {})
        vim.fn.setfperm(vim.fs.dirname(drafts.path()), "rwxr-xr-x")

        assert.same({ vim.log.levels.ERROR }, levels())
        assert.truthy(notes[1].msg:find("can't delete the draft in " .. drafts.path(), 1, true))
      end)

      it("goes before a review comment on the same line", function()
        keep_draft()
        local comments = { { id = "C_1", path = "alpha.txt", line = 9, body = "x" } }

        delete_on(9, comments)
        assert.same({}, deleted_comments)
        delete_on(9, comments)

        assert.same({ "C_1" }, deleted_comments)
      end)

      it("is deleted with no pending review", function()
        keep_draft()
        answers = { { found = { pr = pr } } }
        vim.api.nvim_win_set_cursor(0, { 9, 0 })

        require("changeset.pr").delete()

        assert.same({}, drafts.list(pr))
      end)

      it("written at another head is left alone", function()
        local old = vim.tbl_extend("force", pr, { head = "0000000" })
        keep_draft({ head = old.head })

        delete_on(9, {})

        assert.equal(1, #drafts.list(old))
        assert.truthy(notes[1].msg:find("no review comment on line 9", 1, true))
      end)
    end)
  end)

  describe("delete_listed", function()
    local review_comment = { id = "C_1", path = "alpha.txt", line = 12, outdated = false, body = "x" }

    before_each(function()
      answers = { { found = { pr = pr, review = { id = "PRR_1", comments = { review_comment } } } } }
    end)

    it("asks first, then deletes the review comment it lists with progress, and fetches again", function()
      confirmed = true

      require("changeset.pr").delete_listed({ review_comment = review_comment })

      assert.same({ "Delete the review comment on line 12 of alpha.txt?" }, prompts)
      assert.same({ "C_1" }, deleted_comments)
      assert.same({ { "ask", false }, { "fetch", true }, { "delete_comment", true }, { "fetch", false } }, waits)
    end)

    it("asks GitHub nothing when declined", function()
      require("changeset.pr").delete_listed({ review_comment = review_comment })

      assert.equal(1, #prompts)
      assert.same({}, fetched)
      assert.same({}, deleted_comments)
    end)

    it("names an outdated review comment's file alone", function()
      require("changeset.pr").delete_listed({
        review_comment = { id = "C_2", path = "alpha.txt", outdated = true, original_line = 3, body = "x" },
      })

      assert.same({ "Delete the review comment on alpha.txt?" }, prompts)
    end)

    it("asks, then deletes the draft it lists from GitHub's last answer, even when gh fails", function()
      confirmed = true
      held, answers = { pr = pr }, { { err = "gh: not logged in" } }
      local draft = { path = "alpha.txt", start_line = 8, line = 10, head = HEAD, body = "d" }
      drafts.keep(pr, draft)

      require("changeset.pr").delete_listed({ draft = draft })

      assert.same({ "Delete the draft on lines 8-10 of alpha.txt?" }, prompts)
      assert.same({}, drafts.list(pr))
      assert.same({}, fetched)
      assert.same({ vim.log.levels.INFO }, levels())
    end)
  end)

  describe("the repository", function()
    it("is the tree's from the sidebar", function()
      answers = { { err = "x" } }
      package.loaded["changeset.window"] = {
        is_focused = function()
          return true
        end,
      }

      require("changeset.pr").start()

      assert.same({ "/tree/root" }, fetched)
    end)

    it("is the current buffer's from a file", function()
      answers = { { err = "x" } }
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      dir = vim.fs.normalize(assert(vim.uv.fs_realpath(dir)))
      Fixture.init_repo("main", dir)
      vim.cmd.edit(dir .. "/file.lua")

      require("changeset.pr").start()

      vim.cmd("bwipeout!")
      vim.fn.delete(dir, "rf")
      assert.same({ dir }, fetched)
    end)
  end)

  describe("comment", function()
    local Git = require("changeset.git")
    ---@type changeset.Pr
    local held_pr
    local matches_commit, matches, buf

    before_each(function()
      matches_commit, matches = Git.matches_commit, true
      Git.matches_commit = function()
        return matches
      end
      held = {
        pr = {
          id = "PR_1",
          number = 412,
          host = "github.com",
          owner = "acme",
          name = "widgets",
          head = "abcdef0123456789abcdef0123456789abcdef01",
        },
        review = { id = "PRR_1", comments = {} },
      }
      tree = {
        root = "/tree/root",
        pr = 412,
        collected = true,
        files = { { path = "a.lua", hunks = { { lnum = 3, count = 3, added = 3, removed = 0, old_lnum = 2 } } } },
      }
      buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, "/tree/root/a.lua")
      vim.api.nvim_set_current_buf(buf)
      held_pr = held.pr
      os.remove(drafts.path())
    end)

    after_each(function()
      Git.matches_commit = matches_commit
      vim.api.nvim_buf_delete(buf, { force = true })
      require("changeset.config").setup()
    end)

    ---Asserts one warning containing `text`, and that nothing was opened, fetched or added.
    local function refused(text)
      assert.same({ vim.log.levels.WARN }, levels())
      assert.truthy(notes[1].msg:find(text, 1, true), notes[1].msg)
      assert.same({}, opened)
      assert.same({}, fetched)
      assert.same({}, added)
    end

    it("refuses without a tree, naming the sidebar", function()
      tree = nil
      require("changeset.pr").comment(4, 4)
      refused("sidebar")
    end)

    it("refuses a buffer outside the tree's repository, naming it", function()
      vim.api.nvim_buf_set_name(buf, "/elsewhere/a.lua")
      require("changeset.pr").comment(4, 4)
      refused("/tree/root")
    end)

    it("refuses a buffer that isn't a file, naming the repository", function()
      tree.root = vim.uv.cwd()
      vim.api.nvim_buf_set_name(buf, "changeset://1")
      vim.bo[buf].buftype = "nofile"
      require("changeset.pr").comment(4, 4)
      refused(tree.root)
    end)

    it("refuses an unnamed buffer, naming the repository", function()
      tree.root = vim.uv.cwd()
      vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, false))
      require("changeset.pr").comment(4, 4)
      refused(tree.root)
    end)

    it("refuses while the diff is still being read", function()
      tree.collected = false
      require("changeset.pr").comment(4, 4)
      refused("still reading the diff")
    end)

    it("refuses a diff not measured against an open PR", function()
      tree.pr = nil
      require("changeset.pr").comment(4, 4)
      refused("isn't measured against an open PR")
    end)

    describe("when GitHub hasn't answered", function()
      before_each(function()
        held = nil
      end)

      it("asks it with progress showing, then opens on the pending review it finds", function()
        answers = { { found = { pr = held_pr, review = { id = "PRR_1", comments = {} } } } }

        require("changeset.pr").comment(4, 4)

        assert.same({ { "fetch", true } }, waits)
        assert.equal(0, running())
        assert.equal(1, #opened)
      end)

      it("asks it, then asks to start a pending review when it finds none", function()
        answers = { { found = { pr = held_pr } } }

        require("changeset.pr").comment(4, 4)

        assert.same({ { "fetch", true }, { "ask", false } }, waits)
      end)

      it("opens nothing once the cursor has left the file", function()
        answers = { { found = { pr = held_pr, review = { id = "PRR_1", comments = {} } } } }
        local state = package.loaded["changeset.pending_state"]
        local fetch, other = state.fetch, vim.api.nvim_create_buf(true, false)
        state.fetch = function(root, cb)
          vim.api.nvim_set_current_buf(other)
          fetch(root, cb)
        end

        require("changeset.pr").comment(4, 4)

        vim.api.nvim_buf_delete(other, { force = true })
        assert.same({}, opened)
      end)

      it("warns with gh's text when it can't answer", function()
        answers = { { err = "gh auth expired" } }

        require("changeset.pr").comment(4, 4)

        assert.same({ vim.log.levels.WARN }, levels())
        assert.truthy(notes[1].msg:find("gh auth expired", 1, true))
        assert.same({}, opened)
        assert.equal(0, running())
      end)
    end)

    describe("with no pending review", function()
      ---@type fun(err: string?, review: table?)? Lands the start GitHub was asked for.
      local land

      before_each(function()
        held.review = nil
        land = nil
      end)

      ---Leaves each start in flight until `land` is called.
      local function hold_starts()
        package.loaded["changeset.pending_review"].start = function(id, cb)
          wait("start")
          table.insert(started, id)
          land = cb
        end
      end

      it("asks whether to start one on the PR", function()
        require("changeset.pr").comment(4, 4)

        assert.equal(1, #prompts)
        assert.truthy(prompts[1]:find("#412", 1, true))
      end)

      it("does nothing when declined", function()
        require("changeset.pr").comment(4, 4)

        assert.same({}, opened)
        assert.same({}, started)
        assert.same({}, notes)
      end)

      it("refuses a line outside the PR's diff before asking", function()
        require("changeset.pr").comment(9, 9)

        refused("outside the PR's diff")
        assert.same({}, prompts)
      end)

      it("opens the window at once once confirmed, starting the review behind it with progress", function()
        hold_starts()
        confirmed = true

        require("changeset.pr").comment(4, 4)

        assert.equal(1, #opened)
        assert.same({ "PR_1" }, started)
        assert.same({ { "ask", false }, { "start", true } }, waits)
        assert(land)(nil, { id = "PRR_NEW", comments = {} })
        assert.equal(0, running())
      end)

      it("holds a save until the start lands, then saves into the new review", function()
        hold_starts()
        confirmed = true
        require("changeset.pr").comment(4, 4)
        local results = {}

        opened[1].save("body", function(err)
          table.insert(results, { err = err })
        end)
        assert.same({}, added)
        assert(land)(nil, { id = "PRR_NEW", comments = {} })

        assert.same({ { id = "PRR_NEW", new = { path = "a.lua", line = 4, body = "body" } } }, added)
        assert.same({ {} }, results)
      end)

      it("saves straight into a review whose start has landed", function()
        confirmed = true
        require("changeset.pr").comment(4, 4)

        opened[1].save("body", function() end)

        assert.equal("PRR_NEW", added[1].id)
      end)

      it("keeps a save as a draft when the review can't start, and says so", function()
        hold_starts()
        confirmed = true
        require("changeset.pr").comment(4, 4)
        local results = {}
        opened[1].save("text", function(err)
          table.insert(results, err)
        end)

        assert(land)("boom")

        assert.same({ "boom" }, results)
        assert.same({}, added)
        assert.same({ { path = "a.lua", line = 4, head = held_pr.head, body = "text" } }, drafts.list(held_pr))
        assert.same({ vim.log.levels.ERROR, vim.log.levels.ERROR }, levels())
        assert.truthy(notes[2].msg:find("draft", 1, true))
        assert.equal("failed", progress[#progress].status)
      end)

      it("saves into the pending review GitHub finds when it refuses to start another", function()
        hold_starts()
        confirmed = true
        answers = { { found = { pr = held_pr, review = { id = "PRR_ELSE", comments = {} } } } }
        require("changeset.pr").comment(4, 4)

        assert(land)("User can only have one pending review per pull request")
        opened[1].save("body", function() end)

        assert.equal("PRR_ELSE", added[1].id)
        assert.equal(0, #vim.tbl_filter(function(level)
          return level == vim.log.levels.ERROR
        end, levels()))
        assert.equal(0, running())
      end)

      it("opens and starts nothing once the question has taken the cursor off the file", function()
        local other = vim.api.nvim_create_buf(true, false)
        package.loaded["changeset.confirm"].ask = function(_, yes)
          vim.api.nvim_set_current_buf(other)
          yes()
        end

        require("changeset.pr").comment(4, 4)

        vim.api.nvim_buf_delete(other, { force = true })
        assert.same({}, opened)
        assert.same({}, started)
      end)

      it("reopens a draft on its own lines once confirmed", function()
        confirmed = true
        tree.files[1].hunks = {}
        drafts.keep(held_pr, { path = "a.lua", line = 7, start_line = 5, head = held_pr.head, body = "draft" })

        require("changeset.pr").comment(6, 6)

        assert.equal("draft", opened[1].body)
        assert.equal("Review comment · lines 5-7", opened[1].title)
      end)
    end)

    it("names the PR's head when the clone lacks it", function()
      matches = nil
      require("changeset.pr").comment(4, 4)
      refused("abcdef0")
    end)

    it("refuses a line outside the PR's diff", function()
      require("changeset.pr").comment(9, 9)
      refused("outside the PR's diff")
    end)

    it("refuses every line of a deleted file", function()
      tree.files[1].status = "deleted"
      tree.files[1].hunks = { { lnum = 0, count = 0, added = 0, removed = 3, old_lnum = 1 } }
      require("changeset.pr").comment(1, 1)
      refused("outside the PR's diff")
    end)

    it("refuses a file that differs from the PR's head", function()
      matches = false
      require("changeset.pr").comment(4, 4)
      refused("differs from the PR's head")
    end)

    it("refuses a buffer with unsaved edits", function()
      vim.bo[buf].modified = true
      require("changeset.pr").comment(4, 4)
      refused("differs from the PR's head")
    end)

    it("opens under the line and saves a review comment on it", function()
      require("changeset.pr").comment(4, 4)

      assert.equal(1, #opened)
      assert.equal(4, opened[1].line)
      assert.equal("Review comment · line 4", opened[1].title)
      assert.equal("pending review on #412", opened[1].footer)
      assert.same({ "<C-CR>", "<C-s>" }, opened[1].keys)
      assert.same({}, added)
      assert.same({}, fetched)

      local results = {}
      opened[1].save("body", function(err)
        table.insert(results, { err = err })
      end)

      assert.same({ { id = "PRR_1", new = { path = "a.lua", line = 4, body = "body" } } }, added)
      assert.same({ vim.log.levels.INFO }, levels())
      assert.same({ {} }, results)
      assert.same({ "/tree/root" }, fetched)
    end)

    it("opens under the last line of a range and saves a review comment on the range", function()
      require("changeset.pr").comment(3, 5)

      assert.equal(5, opened[1].line)
      assert.equal("Review comment · lines 3-5", opened[1].title)
      opened[1].save("body", function() end)
      assert.equal(3, added[1].new.start_line)
      assert.equal(5, added[1].new.line)
    end)

    it("reports a failed save and hands the error to the window", function()
      failure = "boom"
      require("changeset.pr").comment(4, 4)

      local results = {}
      opened[1].save("body", function(err)
        table.insert(results, err)
      end)

      assert.same({ vim.log.levels.ERROR }, levels())
      assert.truthy(notes[1].msg:find("boom", 1, true))
      assert.same({ "boom" }, results)
      assert.same({}, fetched)
    end)

    it("saves with the keys review_comment.save names", function()
      require("changeset.config").setup({ review_comment = { save = { "<C-j>" } } })
      require("changeset.pr").comment(4, 4)
      assert.same({ "<C-j>" }, opened[1].keys)
    end)

    ---@param overrides table?
    local function draft(overrides)
      return vim.tbl_extend(
        "force",
        { path = "a.lua", line = 7, start_line = 5, head = held_pr.head, body = "draft" },
        overrides or {}
      )
    end

    it("keeps a closed window's text as a draft on its lines at the PR's head", function()
      require("changeset.pr").comment(3, 5)
      opened[1].keep("text")
      assert.same({ draft({ start_line = 3, line = 5, body = "text" }) }, drafts.list(held_pr))
    end)

    it("keeps no draft of empty text", function()
      require("changeset.pr").comment(4, 4)
      opened[1].keep("")
      assert.same({}, drafts.list(held_pr))
    end)

    it("keeps a draft without calling GitHub", function()
      local client = package.loaded["changeset.pending_review"]
      for name in pairs(client) do
        client[name] = function()
          error(name .. " called")
        end
      end
      require("changeset.pr").comment(4, 4)
      assert.no_errors(function()
        opened[1].keep("text")
      end)
    end)

    it("reopens a draft from any of its lines, on its own lines, even outside the diff", function()
      tree.files[1].hunks = {}
      drafts.keep(held_pr, draft())
      require("changeset.pr").comment(6, 6)
      assert.equal("draft", opened[1].body)
      assert.equal(7, opened[1].line)
      assert.equal("Review comment · lines 5-7", opened[1].title)
    end)

    it("doesn't reopen a draft written at another head", function()
      drafts.keep(held_pr, draft({ start_line = nil, line = 4, head = "0000000" }))
      require("changeset.pr").comment(4, 4)
      assert.is_nil(opened[1].body)
      assert.equal("Review comment · line 4", opened[1].title)
    end)

    it("keeps a rejected save's text as a draft and says so", function()
      failure = "boom"
      require("changeset.pr").comment(4, 4)
      opened[1].save("text", function() end)
      assert.same({ { path = "a.lua", line = 4, head = held_pr.head, body = "text" } }, drafts.list(held_pr))
      assert.same({ vim.log.levels.ERROR }, levels())
      assert.truthy(notes[1].msg:find("boom", 1, true))
      assert.truthy(notes[1].msg:find("draft", 1, true))
    end)

    it("says a rejected save's text wasn't kept when the record can't be written", function()
      failure = "boom"
      vim.fn.mkdir(vim.fs.dirname(drafts.path()), "p")
      vim.fn.setfperm(vim.fs.dirname(drafts.path()), "r-xr-xr-x")
      require("changeset.pr").comment(4, 4)
      opened[1].save("text", function() end)
      vim.fn.setfperm(vim.fs.dirname(drafts.path()), "rwxr-xr-x")
      assert.same({ vim.log.levels.ERROR }, levels())
      assert.truthy(notes[1].msg:find("nor keep it in " .. drafts.path(), 1, true))
    end)

    it("drops a reopened draft once its save is taken", function()
      drafts.keep(held_pr, draft())
      require("changeset.pr").comment(6, 6)
      opened[1].save("draft", function() end)
      assert.same({}, drafts.list(held_pr))
    end)

    describe("open_listed", function()
      local review_comment = { id = "C_1", path = "a.lua", start_line = 3, line = 4, outdated = false, body = "old" }

      it("reopens the draft it lists, though a narrower one ends on its line", function()
        drafts.keep(held_pr, draft())
        drafts.keep(held_pr, draft({ start_line = nil, body = "narrow" }))

        require("changeset.pr").open_listed({ draft = draft() })

        assert.equal("draft", opened[1].body)
        assert.equal("Review comment · lines 5-7", opened[1].title)
      end)

      it("opens a review comment under its lines, editable, saying a save updates it", function()
        require("changeset.pr").open_listed({ review_comment = review_comment })

        assert.equal("old", opened[1].body)
        assert.equal(4, opened[1].line)
        assert.equal("Edit review comment · lines 3-4", opened[1].title)
        assert.truthy(opened[1].footer:find("#412", 1, true))
        for _, text in ipairs({ opened[1].footer, opened[1].save_desc, opened[1].close_desc }) do
          assert.is_nil(text:lower():find("add", 1, true), text)
          assert.truthy(text:lower():find("edit", 1, true) or text:lower():find("update", 1, true), text)
        end
      end)

      it("updates the review comment on a save, and fetches again", function()
        require("changeset.pr").open_listed({ review_comment = review_comment })
        local results = {}

        opened[1].save("new", function(err)
          table.insert(results, { err = err })
        end)

        assert.same({ { id = "C_1", body = "new" } }, updated)
        assert.same({}, added)
        assert.same({ {} }, results)
        assert.same({ vim.log.levels.INFO }, levels())
        assert.same({ "/tree/root" }, fetched)
      end)

      it("hands a refused update to the window and keeps no draft", function()
        failure = "boom"
        require("changeset.pr").open_listed({ review_comment = review_comment })
        local results = {}

        opened[1].save("new", function(err)
          table.insert(results, err)
        end)

        assert.same({ "boom" }, results)
        assert.same({ vim.log.levels.ERROR }, levels())
        assert.same({}, drafts.list(held_pr))
      end)

      it("keeps no draft of an edit closed unsaved, and says the review comment kept its text", function()
        require("changeset.pr").open_listed({ review_comment = review_comment })

        opened[1].keep("changed")

        assert.same({}, drafts.list(held_pr))
        assert.same({ vim.log.levels.INFO }, levels())
      end)

      it("says nothing of an edit closed with its text unchanged", function()
        require("changeset.pr").open_listed({ review_comment = review_comment })

        opened[1].keep("old")

        assert.same({}, notes)
      end)

      it("asks to delete the review comment when the edit closes blank", function()
        confirmed = true
        answers = { { found = { pr = held_pr, review = { id = "PRR_1", comments = { review_comment } } } } }
        require("changeset.pr").open_listed({ review_comment = review_comment })

        opened[1].keep("  \n")

        assert.is_true(vim.wait(1000, function()
          return #deleted_comments > 0
        end))
        assert.same({ "Delete the review comment on lines 3-4 of a.lua?" }, prompts)
        assert.same({ "C_1" }, deleted_comments)
        assert.same({}, updated)
      end)

      it("opens nothing for a review comment with no line, and says why", function()
        local outdated = { id = "C_2", path = "a.lua", outdated = true, original_line = 3, body = "old" }

        require("changeset.pr").open_listed({ review_comment = outdated })

        assert.same({}, opened)
        assert.same({ vim.log.levels.INFO }, levels())
        assert.truthy(notes[1].msg:find("outdated", 1, true))
      end)
    end)

    it("drops a draft kept while its save was in flight, once the save is taken", function()
      local answer
      package.loaded["changeset.pending_review"].add_comment = function(_, _, cb)
        answer = cb
      end
      require("changeset.pr").comment(4, 4)
      opened[1].save("text", function() end)
      opened[1].keep("text")
      answer(nil)
      assert.same({}, drafts.list(held_pr))
    end)
  end)
end)
