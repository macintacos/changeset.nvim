local Fixture = require("support.git")

local STUBBED =
  { "changeset.pending_state", "changeset.pending_review", "changeset.build", "changeset.pr", "changeset.window" }

describe("changeset.pr", function()
  local notify, input, notes, prompts, fetched, started, deleted, deleted_comments
  ---@type { err: string?, found: table? }[] What each fetch answers, in order; the last repeats.
  local answers
  ---@type string What `vim.fn.input` answers.
  local choice
  ---@type string? What the client's `start` or `delete` fails with.
  local failure
  local tree

  local pr = { id = "PR_1", number = 412 }

  before_each(function()
    notes, prompts, fetched, started, deleted, deleted_comments = {}, {}, {}, {}, {}, {}
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
      fetch = function(root, cb)
        table.insert(fetched, root)
        local answer = answers[math.min(#fetched, #answers)]
        if cb then
          cb(answer.err, answer.found)
        end
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
    }
    package.loaded["changeset.build"] = {
      current = function()
        return tree
      end,
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
end)
