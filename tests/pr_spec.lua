local Fixture = require("support.git")

local STUBBED = {
  "changeset.pending_state",
  "changeset.pending_review",
  "changeset.build",
  "changeset.pr",
  "changeset.window",
  "changeset.review_comments",
  "changeset.review_comment_window",
}

describe("changeset.pr", function()
  local notify, input, notes, prompts, fetched, started, deleted, deleted_comments, added, opened
  ---@type table? What `pending_state.get` answers.
  local held
  ---@type { err: string?, found: table? }[] What each fetch answers, in order; the last repeats.
  local answers
  ---@type string What `vim.fn.input` answers.
  local choice
  ---@type string? What the client's `start`, `delete` or `add_comment` fails with.
  local failure
  local tree

  local pr = { id = "PR_1", number = 412 }

  before_each(function()
    notes, prompts, fetched, started, deleted, deleted_comments, added, opened = {}, {}, {}, {}, {}, {}, {}, {}
    held = nil
    answers, choice, failure = {}, "", nil
    tree = { root = "/tree/root", pr = 412 }
    notify, input = vim.notify, vim.fn.input
    vim.notify = function(msg, level)
      table.insert(notes, { msg = msg, level = level })
    end
    vim.fn.input = function(opts)
      table.insert(prompts, opts.prompt)
      return choice
    end
    package.loaded["changeset.pending_state"] = {
      subscribe = function() end,
      fetch = function(root, cb)
        table.insert(fetched, root)
        local answer = answers[math.min(#fetched, #answers)]
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
        table.insert(started, id)
        cb(failure)
      end,
      delete = function(id, cb)
        table.insert(deleted, id)
        cb(failure)
      end,
      delete_comment = function(id, cb)
        table.insert(deleted_comments, id)
        cb(failure)
      end,
      add_comment = function(id, new, cb)
        table.insert(added, { id = id, new = new })
        cb(failure)
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
    vim.notify, vim.fn.input = notify, input
    for _, name in ipairs(STUBBED) do
      package.loaded[name] = nil
    end
  end)

  local function levels()
    return vim.tbl_map(function(note)
      return note.level
    end, notes)
  end

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

    for _, answer in ipairs({ "n", "", "nope y" }) do
      it(("changes nothing when the answer is %q"):format(answer), function()
        answers, choice = { { found = { pr = pr, review = review } } }, answer

        require("changeset.pr").abandon()

        assert.equal(1, #prompts)
        assert.same({}, deleted)
        assert.equal(1, #fetched)
      end)
    end

    for _, answer in ipairs({ "y", " YES " }) do
      it(("deletes the review when the answer is %q"):format(answer), function()
        answers, choice = { { found = { pr = pr, review = review } } }, answer

        require("changeset.pr").abandon()

        assert.same({ "R_1" }, deleted)
      end)
    end

    it("deletes the review once confirmed, naming the PR and its review comments", function()
      answers, choice = { { found = { pr = pr, review = review } } }, "y"

      require("changeset.pr").abandon()

      assert.truthy(prompts[1]:find("#412", 1, true))
      assert.truthy(prompts[1]:find("3 review comments", 1, true))
      assert.same({ "R_1" }, deleted)
      assert.same({ vim.log.levels.INFO }, levels())
      assert.equal(2, #fetched)
    end)

    it("reports a failed delete and still fetches again", function()
      answers, choice, failure = { { found = { pr = pr, review = review } } }, "y", "network down"

      require("changeset.pr").abandon()

      assert.same({ vim.log.levels.ERROR }, levels())
      assert.truthy(notes[1].msg:find("network down", 1, true))
      assert.equal(2, #fetched)
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
    local matches_commit, matches, buf

    before_each(function()
      matches_commit, matches = Git.matches_commit, true
      Git.matches_commit = function()
        return matches
      end
      held = {
        pr = { id = "PR_1", number = 412, head = "abcdef0123456789abcdef0123456789abcdef01" },
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

    it("asks for a review to be started when GitHub hasn't answered", function()
      held = nil
      require("changeset.pr").comment(4, 4)
      refused("start the review with `:Changeset pr start`")
    end)

    it("asks for a review to be started when there is none", function()
      held.review = nil
      require("changeset.pr").comment(4, 4)
      refused("start the review with `:Changeset pr start`")
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
      assert.equal("line 4", opened[1].title)
      assert.equal("pending review on #412", opened[1].footer)
      assert.same({ "<C-CR>", "<C-s>" }, opened[1].keys)
      assert.same({}, added)

      local results = {}
      opened[1].save("body", function(err)
        table.insert(results, { err = err })
      end)

      assert.same({ { id = "PRR_1", new = { path = "a.lua", line = 4, body = "body" } } }, added)
      assert.same({ vim.log.levels.INFO }, levels())
      assert.same({ {} }, results)
      assert.same({}, fetched)
    end)

    it("opens under the last line of a range and saves a review comment on the range", function()
      require("changeset.pr").comment(3, 5)

      assert.equal(5, opened[1].line)
      assert.equal("lines 3-5", opened[1].title)
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
  end)
end)
