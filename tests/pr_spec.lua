local Fixture = require("support.git")

local STUBBED = { "changeset.pending_state", "changeset.pending_review", "changeset.build", "changeset.pr" }

describe("changeset.pr", function()
  local notify, confirm, notes, prompts, fetched, started, deleted
  ---@type { err: string?, found: table? }[] What each fetch answers, in order; the last repeats.
  local answers
  ---@type integer What `vim.fn.confirm` answers.
  local choice
  ---@type string? What the client's `start` or `delete` fails with.
  local failure
  local tree

  local pr = { id = "PR_1", number = 412 }

  before_each(function()
    notes, prompts, fetched, started, deleted = {}, {}, {}, {}, {}
    answers, choice, failure = {}, 2, nil
    tree = { root = "/tree/root", pr = 412 }
    notify, confirm = vim.notify, vim.fn.confirm
    vim.notify = function(msg, level)
      table.insert(notes, { msg = msg, level = level })
    end
    vim.fn.confirm = function(msg)
      table.insert(prompts, msg)
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
    }
    package.loaded["changeset.build"] = {
      current = function()
        return tree
      end,
    }
    package.loaded["changeset.pr"] = nil
  end)

  after_each(function()
    vim.notify, vim.fn.confirm = notify, confirm
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

    for _, answer in ipairs({ 2, 0 }) do
      it("changes nothing when confirm answers " .. answer, function()
        answers, choice = { { found = { pr = pr, review = review } } }, answer

        require("changeset.pr").abandon()

        assert.equal(1, #prompts)
        assert.same({}, deleted)
        assert.equal(1, #fetched)
      end)
    end

    it("deletes the review once confirmed, naming the PR and its review comments", function()
      answers, choice = { { found = { pr = pr, review = review } } }, 1

      require("changeset.pr").abandon()

      assert.truthy(prompts[1]:find("#412", 1, true))
      assert.truthy(prompts[1]:find("3 review comments", 1, true))
      assert.same({ "R_1" }, deleted)
      assert.same({ vim.log.levels.INFO }, levels())
      assert.equal(2, #fetched)
    end)

    it("reports a failed delete and still fetches again", function()
      answers, choice, failure = { { found = { pr = pr, review = review } } }, 1, "network down"

      require("changeset.pr").abandon()

      assert.same({ vim.log.levels.ERROR }, levels())
      assert.truthy(notes[1].msg:find("network down", 1, true))
      assert.equal(2, #fetched)
    end)
  end)

  describe("the repository", function()
    it("is the tree's from the sidebar", function()
      answers = { { err = "x" } }
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(buf)
      vim.bo[buf].filetype = "changeset"

      require("changeset.pr").start()

      vim.api.nvim_buf_delete(buf, { force = true })
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
