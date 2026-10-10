local Dialog = require("support.dialog")
local Fixture = require("support.git")
local Notify = require("support.notify")
local Paths = require("changeset.paths")
local comment_store = require("changeset.comment_store")
local present = require("support.present")

describe("changeset.reviewing", function()
  ---@module "changeset.reviewing"
  local reviewing
  local restore_notify ---@type fun()
  local notes ---@type support.notify.Note[]
  local windows ---@type changeset.ReviewCommentWindowOpts[]
  local dir ---@type string
  local tree ---@type { root: string }?
  local focused ---@type boolean
  local echoes ---@type string[]
  local echo ---@type function

  ---The options of the window opened last.
  ---@return changeset.ReviewCommentWindowOpts
  local function window()
    return present(windows[#windows], "no review comment window opened")
  end

  before_each(function()
    os.remove(comment_store.path())
    windows, focused, tree = {}, false, nil
    echoes, echo = {}, vim.api.nvim_echo
    vim.api.nvim_echo = function(chunks)
      table.insert(echoes, present(chunks[1])[1])
      return -1
    end
    notes, restore_notify = Notify.capture()
    package.loaded["changeset.review_comment_window"] = {
      open = function(opts)
        table.insert(windows, opts)
      end,
      watch = function() end,
    }
    package.loaded["changeset.window"] = {}
    package.loaded["changeset.origin"] = {
      current = function()
        return { repository = focused and tree and tree.root or Paths.root(0), sidebar = focused }
      end,
    }
    package.loaded["changeset.reviewing"] = nil
    reviewing = require("changeset.reviewing")
    dir = vim.fn.tempname()
  end)

  after_each(function()
    restore_notify()
    vim.api.nvim_echo = echo
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(dir, "rf")
    vim.cmd("silent! fclose!")
    for _, name in ipairs({ "changeset.review_comment_window", "changeset.window" }) do
      package.loaded[name] = nil
    end
    package.loaded["changeset.origin"] = nil
    package.loaded["changeset.herdr"] = nil
  end)

  ---Opens `a.lua`, ten lines long, in a fresh repository.
  local function edit_file()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    dir = vim.fs.normalize(present(vim.uv.fs_realpath(dir)))
    Fixture.init_repo("main", dir)
    vim.fn.writefile(vim.split(("x"):rep(10, "\n"), "\n"), dir .. "/a.lua")
    vim.cmd.edit(dir .. "/a.lua")
  end

  ---Whether any float is open: a dialog asking.
  ---@return boolean
  local function asking()
    return vim.iter(vim.api.nvim_list_wins()):any(function(win)
      return vim.api.nvim_win_get_config(win).relative ~= ""
    end)
  end

  ---Presses `keys` in the open dialog, then waits for `done`.
  ---@param keys string
  ---@param done fun(): boolean
  local function reply(keys, done)
    Dialog.press(keys)
    vim.wait(1000, done, 10)
  end

  ---@param fields table?
  ---@return changeset.ReviewComment
  local function comment(fields)
    local merged = vim.tbl_extend("force", { path = "a.lua", line = 4, body = "hi" }, fields or {})
    return merged --[[@as changeset.ReviewComment]]
  end

  describe("comment", function()
    it("saves a body without its leading blank lines, keeping the first line's indentation", function()
      edit_file()

      reviewing.comment(4, 4)
      window().save("\n \n  the point\nmore", function() end)

      assert.equal("  the point\nmore", present(comment_store.list(dir)[1]).body)
    end)

    it("leaves a selection of the first line a comment on that line", function()
      edit_file()

      reviewing.comment(1, 1)

      assert.equal(1, window().comment.line)
    end)

    it("opens under the range's last line and keeps a save on the range", function()
      edit_file()

      reviewing.comment(2, 4)
      assert.equal(4, window().line)
      local done = false
      window().save("note", function(err)
        done = err == nil
      end)

      assert.is_true(done)
      assert.same({ comment({ start_line = 2, body = "note" }) }, comment_store.list(dir))
    end)

    it("keeps the text of a window closed without saving as a draft, and says so", function()
      edit_file()

      reviewing.comment(4, 4)
      window().keep("typed")

      assert.same({ comment({ body = "typed", draft = true }) }, comment_store.list(dir))
      vim.wait(100, function()
        return #notes > 0
      end, 10)
      assert.equal(vim.log.levels.INFO, present(notes[1]).level)
    end)

    it("keeps nothing of a window closed blank", function()
      edit_file()

      reviewing.comment(4, 4)
      window().keep(" \n")

      assert.same({}, comment_store.list(dir))
    end)

    it("opens the comment already covering the last line, to edit it", function()
      edit_file()
      comment_store.keep(dir, comment({ start_line = 3, line = 5, body = "old" }))

      reviewing.comment(4, 4)

      assert.equal(5, window().line)
      assert.equal("old", window().body)
    end)

    it("opens a new comment on a selected range whose last line another comment covers", function()
      edit_file()
      comment_store.keep(dir, comment({ line = 5 }))

      reviewing.comment(3, 5)

      assert.is_nil(window().body)
      window().save("range", function() end)
      assert.equal(2, #comment_store.list(dir))
    end)

    it("reopens the comment on exactly the selected range", function()
      edit_file()
      comment_store.keep(dir, comment({ line = 5 }))
      comment_store.keep(dir, comment({ start_line = 3, line = 5, body = "range" }))

      reviewing.comment(3, 5)

      assert.equal("range", window().body)
    end)

    it("refuses in a modified buffer", function()
      edit_file()
      vim.api.nvim_buf_set_lines(0, 0, 0, false, { "new" })

      reviewing.comment(4, 4)

      assert.same({}, windows)
      assert.equal(vim.log.levels.WARN, present(notes[1]).level)
    end)

    it("keeps the window open when the comment can't be stored", function()
      edit_file()
      vim.fn.mkdir(vim.fs.dirname(comment_store.path()), "p")
      vim.fn.writefile({ "[1,2]" }, comment_store.path())

      reviewing.comment(4, 4)
      local err ---@type string?
      window().save("lost?", function(e)
        err = e
      end)

      os.remove(comment_store.path())
      vim.wait(100, function()
        return #notes > 0
      end, 10)
      assert.truthy(err)
      assert.equal(vim.log.levels.ERROR, present(notes[1]).level)
    end)

    it("keeps a comment saved on the range meanwhile when closed blank", function()
      edit_file()
      reviewing.comment(4, 4)
      local first = window()
      comment_store.keep(dir, comment({ body = "saved meanwhile" }))

      first.keep("")

      assert.same({ comment({ body = "saved meanwhile" }) }, comment_store.list(dir))
    end)

    it("refuses a buffer that isn't a file, naming the repository", function()
      edit_file()
      vim.cmd.enew()
      vim.bo.buftype = "nofile"

      reviewing.comment(1, 1)

      assert.same({}, windows)
      assert.equal(vim.log.levels.WARN, present(notes[1]).level)
      assert.truthy((present(notes[1]).msg:find("Changeset: ", 1, true)))
    end)
  end)

  describe("comment_here", function()
    it("comments the whole file from its first line, keeping a save on no line", function()
      edit_file()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      reviewing.comment_here()

      assert.equal(1, window().line)
      window().save("the file", function() end)
      assert.same({ { path = "a.lua", body = "the file" } }, comment_store.list(dir))
    end)

    it("opens the whole file's comment to edit from its first line", function()
      edit_file()
      comment_store.keep(dir, comment({ line = 1, body = "line one" }))
      comment_store.keep(dir, { path = "a.lua", body = "the file" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      reviewing.comment_here()

      assert.equal("the file", window().body)
    end)

    it("heads a whole file's window with the file's icon", function()
      edit_file()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      reviewing.comment_here()

      assert.is_table(window().icon)
    end)

    it("comments the cursor's line anywhere past the first", function()
      edit_file()
      vim.api.nvim_win_set_cursor(0, { 3, 0 })

      reviewing.comment_here()

      assert.equal(3, window().comment.line)
    end)

    it("heads a line's window with the bubble that marks its line", function()
      edit_file()
      vim.api.nvim_win_set_cursor(0, { 3, 0 })

      reviewing.comment_here()

      assert.same({ require("changeset.review_comments").glyph(window().comment) }, window().icon)
    end)
  end)

  describe("open", function()
    it("replaces the comment's body on a save", function()
      edit_file()
      comment_store.keep(dir, comment())

      reviewing.open(comment())
      window().save("new", function() end)

      assert.same({ comment({ body = "new" }) }, comment_store.list(dir))
    end)

    it("asks, once the window has closed, to delete a comment closed blank", function()
      edit_file()
      comment_store.keep(dir, comment())

      reviewing.open(comment())
      window().keep("")
      assert.is_false(asking())
      reply("D", function()
        return #comment_store.list(dir) == 0
      end)

      assert.same({}, comment_store.list(dir))
    end)

    it("keeps the edit window open when the comment can't be stored", function()
      edit_file()
      comment_store.keep(dir, comment())
      reviewing.open(comment())
      vim.fn.writefile({ "[1,2]" }, comment_store.path())

      local err ---@type string?
      window().save("new", function(e)
        err = e
      end)

      os.remove(comment_store.path())
      vim.wait(100, function()
        return #notes > 0
      end, 10)
      assert.truthy(err)
    end)

    it("keeps an edit closed without saving as a draft, and says so", function()
      edit_file()
      comment_store.keep(dir, comment())

      reviewing.open(comment())
      window().keep("changed")

      assert.same({ comment({ body = "changed", draft = true }) }, comment_store.list(dir))
      vim.wait(100, function()
        return #notes > 0
      end, 10)
      assert.equal(vim.log.levels.INFO, present(notes[1]).level)
    end)

    it("leaves a saved comment closed unchanged saved", function()
      edit_file()
      comment_store.keep(dir, comment())

      reviewing.open(comment())
      window().keep("hi")

      assert.same({ comment() }, comment_store.list(dir))
      assert.same({}, notes)
    end)

    it("saves a draft as a saved comment", function()
      edit_file()
      comment_store.keep(dir, comment({ draft = true }))

      reviewing.open(comment({ draft = true }))
      window().save("hi", function() end)

      assert.same({ comment() }, comment_store.list(dir))
    end)

    it("resumes a draft's text under a title that says it is one", function()
      edit_file()
      comment_store.keep(dir, comment({ draft = true }))

      reviewing.comment(4, 4)

      assert.equal("hi", window().body)
      assert.truthy(window().title:lower():find("draft"), window().title)
    end)

    it("heads a draft's window with the draft's own bubble", function()
      edit_file()
      comment_store.keep(dir, comment({ draft = true }))

      reviewing.comment(4, 4)

      assert.equal(require("changeset.highlights").REVIEW_COMMENT_DRAFT_HL, present(window().icon)[2])
    end)
  end)

  describe("delete", function()
    it("deletes the narrowest comment on the cursor's line without asking", function()
      edit_file()
      comment_store.keep(dir, comment({ start_line = 1, line = 6 }))
      comment_store.keep(dir, comment({ start_line = 3 }))
      vim.api.nvim_win_set_cursor(0, { 4, 0 })

      reviewing.delete()

      assert.is_false(asking())
      assert.same({ comment({ start_line = 1, line = 6 }) }, comment_store.list(dir))
    end)

    it("deletes the whole file's comment from its first line", function()
      edit_file()
      comment_store.keep(dir, comment({ line = 1 }))
      comment_store.keep(dir, { path = "a.lua", body = "the file" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      reviewing.delete()

      assert.same({ comment({ line = 1 }) }, comment_store.list(dir))
    end)

    it("deletes the comment on the first line when the whole file has none", function()
      edit_file()
      comment_store.keep(dir, comment({ line = 1 }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      reviewing.delete()

      assert.same({}, comment_store.list(dir))
    end)

    it("says when the line has no comment", function()
      edit_file()
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      reviewing.delete()

      assert.equal(vim.log.levels.INFO, present(notes[1]).level)
    end)

    it("refuses in a modified buffer", function()
      edit_file()
      comment_store.keep(dir, comment())
      vim.api.nvim_win_set_cursor(0, { 4, 0 })
      vim.api.nvim_buf_set_lines(0, 0, 0, false, { "new" })

      reviewing.delete()

      assert.equal(vim.log.levels.WARN, present(notes[1]).level)
      assert.same({ comment() }, comment_store.list(dir))
    end)
  end)

  describe("draft", function()
    it("makes the saved comment on the cursor's line, the narrowest, a draft, saying so", function()
      edit_file()
      comment_store.keep(dir, comment({ start_line = 1, line = 6 }))
      comment_store.keep(dir, comment())
      vim.api.nvim_win_set_cursor(0, { 4, 0 })

      reviewing.draft()

      assert.same({ comment({ start_line = 1, line = 6 }), comment({ draft = true }) }, comment_store.list(dir))
      assert.same({
        msg = "Changeset: kept the review comment on line 4 of a.lua as a draft",
        level = vim.log.levels.INFO,
      }, notes[#notes])
    end)

    it("saves the draft on the cursor's line, saying so", function()
      edit_file()
      comment_store.keep(dir, comment({ draft = true }))
      vim.api.nvim_win_set_cursor(0, { 4, 0 })

      reviewing.draft()

      assert.same({ comment() }, comment_store.list(dir))
      assert.equal("Changeset: saved the review comment on line 4 of a.lua", notes[#notes].msg)
    end)

    it("switches the whole file's comment from its first line", function()
      edit_file()
      comment_store.keep(dir, comment({ line = 1 }))
      comment_store.keep(dir, { path = "a.lua", body = "the file" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      reviewing.draft()

      assert.same(
        { comment({ line = 1 }), { path = "a.lua", body = "the file", draft = true } },
        comment_store.list(dir)
      )
    end)

    it("says when the line has no comment", function()
      edit_file()
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      reviewing.draft()

      assert.same({ msg = "Changeset: no review comment on line 2", level = vim.log.levels.INFO }, notes[1])
    end)

    it("refuses in a modified buffer", function()
      edit_file()
      comment_store.keep(dir, comment())
      vim.api.nvim_win_set_cursor(0, { 4, 0 })
      vim.api.nvim_buf_set_lines(0, 0, 0, false, { "new" })

      reviewing.draft()

      assert.equal(vim.log.levels.WARN, present(notes[1]).level)
      assert.same({ comment() }, comment_store.list(dir))
    end)
  end)

  describe("ask_delete", function()
    it("asks about the comment by its place and its words", function()
      edit_file()
      comment_store.keep(dir, comment({ start_line = 3, body = "first\nsecond" }))

      reviewing.ask_delete(comment({ start_line = 3, body = "first\nsecond" }))

      local lines = table.concat(Dialog.lines(), "\n")
      assert.truthy((lines:find("a.lua:3-4", 1, true)))
      assert.truthy((lines:find("▎ first\n%s*▎ second")))
    end)

    it("deletes the comment once confirmed", function()
      edit_file()
      comment_store.keep(dir, comment())

      reviewing.ask_delete(comment())
      reply("D", function()
        return #comment_store.list(dir) == 0
      end)

      assert.same({}, comment_store.list(dir))
    end)

    it("deletes an emptied comment from the repository it was opened in", function()
      edit_file()
      local first = dir
      comment_store.keep(first, comment())
      reviewing.open(comment())
      local other = vim.fs.normalize(present(vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()))
      vim.fn.mkdir(other, "p")
      Fixture.init_repo("main", other)
      vim.fn.writefile({ "y" }, other .. "/b.lua")
      vim.cmd.edit(other .. "/b.lua")

      window().keep("")
      vim.wait(1000, function()
        return asking()
      end, 10)
      reply("D", function()
        return #comment_store.list(first) == 0
      end)
      vim.fn.delete(other, "rf")

      assert.same({}, comment_store.list(first))
    end)

    it("says nothing was deleted when the comment is no longer stored", function()
      edit_file()

      reviewing.ask_delete(comment())
      reply("D", function()
        return #notes > 0
      end)

      assert.is_nil((present(notes[1]).msg:find("deleted", 1, true)))
    end)

    it("keeps the comment when declined", function()
      edit_file()
      comment_store.keep(dir, comment())

      reviewing.ask_delete(comment())
      reply("<CR>", function()
        return not asking()
      end)

      assert.same({ comment() }, comment_store.list(dir))
    end)
  end)

  describe("from_window", function()
    ---A review comment window on `comment()` whose source window has closed.
    local function orphaned()
      local calls = {}
      local open = {
        source = -1,
        comment = comment(),
        text = function()
          return ""
        end,
        discard = function()
          table.insert(calls, "discard")
        end,
        close = function()
          table.insert(calls, "close")
        end,
        resume = function()
          table.insert(calls, "resume")
        end,
      }
      -- Only the members an orphaned window's close path reads; the rest of the class is never touched.
      local orphan = open --[[@as changeset.ReviewCommentWindow]]
      return orphan, calls
    end

    it("deletes from the current repository once the source window has closed", function()
      edit_file()
      local open, calls = orphaned()

      reviewing.from_window(open, "comment del", function() end)

      assert.same({ "discard" }, calls)
    end)

    it("goes to the comment saved last once the source window has closed", function()
      edit_file()
      local open, calls = orphaned()

      reviewing.from_window(open, "comment last", function() end)

      assert.same({ "close" }, calls)
    end)
  end)

  describe("next_comment and prev_comment", function()
    ---Writes `b.lua` beside `a.lua` and keeps comments on a.lua:4, a.lua:2-7 and b.lua:3.
    local function three_comments()
      edit_file()
      vim.fn.writefile(vim.split(("y"):rep(10, "\n"), "\n"), dir .. "/b.lua")
      comment_store.keep(dir, comment({ path = "b.lua", line = 3 }))
      comment_store.keep(dir, comment())
      comment_store.keep(dir, comment({ start_line = 2, line = 7 }))
    end

    ---@return string path, integer line
    local function where()
      return vim.fs.basename(vim.api.nvim_buf_get_name(0)), vim.api.nvim_win_get_cursor(0)[1]
    end

    it("goes to the first line of the next comment by path, then first line", function()
      three_comments()
      vim.api.nvim_win_set_cursor(0, { 2, 3 })

      reviewing.next_comment(1)
      assert.same({ "a.lua", 4 }, { where() })
      assert.equal(0, vim.api.nvim_win_get_cursor(0)[2])
      assert.equal("review comment 2 of 3", echoes[1])

      reviewing.next_comment(1)
      assert.same({ "b.lua", 3 }, { where() })
    end)

    it("goes to the previous comment, wrapping past the first and saying so", function()
      three_comments()
      vim.api.nvim_win_set_cursor(0, { 4, 0 })

      reviewing.prev_comment(1)
      assert.same({ "a.lua", 2 }, { where() })
      reviewing.prev_comment(1)
      assert.same({ "b.lua", 3 }, { where() })
      assert.matches("review comment 3 of 3.*wrapped", present(echoes[2]))
    end)

    it("skips a comment whose file is gone", function()
      three_comments()
      comment_store.keep(dir, comment({ path = "gone.lua", line = 1 }))
      vim.cmd.edit(dir .. "/b.lua")
      vim.api.nvim_win_set_cursor(0, { 3, 0 })

      reviewing.next_comment(1)

      assert.same({ "a.lua", 2 }, { where() })
    end)

    it("jumps through the sidebar's window from the sidebar", function()
      three_comments()
      focused, tree = true, { root = dir }
      local committed = {}
      package.loaded["changeset.window"].commit = function(commit)
        table.insert(committed, commit)
        return true
      end

      reviewing.next_comment(1)

      assert.same({ { path = dir .. "/a.lua", lnum = 2, how = "reuse" } }, committed)
    end)

    it("lands on the last line of a file that shrank under its comment, and moves on from it", function()
      three_comments()
      comment_store.keep(dir, comment({ line = 50 }))
      vim.api.nvim_win_set_cursor(0, { 5, 0 })

      reviewing.next_comment(1)
      assert.same({ "a.lua", 10 }, { where() })
      reviewing.next_comment(1)
      assert.same({ "b.lua", 3 }, { where() })
    end)

    it("jumps in the previous window from a window that holds no file", function()
      three_comments()
      local file_win = vim.api.nvim_get_current_win()
      vim.cmd("new")
      vim.bo.buftype = "nofile"
      local scratch = vim.api.nvim_get_current_buf()

      reviewing.next_comment(1)

      assert.equal(file_win, vim.api.nvim_get_current_win())
      assert.same({ "a.lua", 2 }, { where() })
      assert.equal(1, #vim.fn.win_findbuf(scratch))
      vim.api.nvim_buf_delete(scratch, { force = true })
    end)

    it("refuses, without raising, from a window it can't put a file in with no file window before it", function()
      three_comments()
      vim.cmd("silent! only")
      vim.wo.winfixbuf = true
      vim.cmd("vnew")
      vim.bo.buftype = "nofile"
      local scratch = vim.api.nvim_get_current_buf()
      vim.cmd("wincmd p")

      local ok, err = pcall(reviewing.next_comment, 1)

      vim.wo.winfixbuf = false
      vim.api.nvim_buf_delete(scratch, { force = true })
      assert.is_truthy(ok, tostring(err))
      assert.equal(vim.log.levels.WARN, present(notes[1]).level)
    end)

    it("passes over a comment on a whole file", function()
      three_comments()
      comment_store.keep(dir, { path = "b.lua", body = "the file" })
      vim.api.nvim_win_set_cursor(0, { 8, 0 })

      reviewing.next_comment(1)

      assert.same({ "b.lua", 3 }, { where() })
      assert.equal("review comment 3 of 3", echoes[1])
    end)

    it("steps over as many comments as its count", function()
      three_comments()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      reviewing.next_comment(2)
      assert.same({ "a.lua", 4 }, { where() })
      reviewing.prev_comment(3)
      assert.same({ "a.lua", 4 }, { where() })
      assert.equal("review comment 2 of 3, wrapped", echoes[#echoes])
    end)

    it("keeps focus where it was when it refuses the file window before it", function()
      three_comments()
      vim.api.nvim_buf_set_lines(0, 0, 0, false, { "new" })
      vim.cmd("new")
      vim.bo.buftype = "nofile"
      local scratch_win = vim.api.nvim_get_current_win()

      reviewing.next_comment(1)

      assert.equal(scratch_win, vim.api.nvim_get_current_win())
      assert.equal(vim.log.levels.WARN, present(notes[1]).level)
      vim.api.nvim_buf_delete(0, { force = true })
    end)

    it("refuses in a modified buffer", function()
      three_comments()
      vim.api.nvim_buf_set_lines(0, 0, 0, false, { "new" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      reviewing.next_comment(1)

      assert.same({ "a.lua", 1 }, { where() })
      assert.equal(vim.log.levels.WARN, present(notes[1]).level)
    end)

    it("refuses when the comment's file has unsaved edits", function()
      three_comments()
      vim.cmd.edit(dir .. "/b.lua")
      vim.api.nvim_buf_set_lines(0, 0, 0, false, { "new" })
      vim.cmd("hide edit " .. dir .. "/a.lua")
      vim.api.nvim_win_set_cursor(0, { 9, 0 })

      reviewing.next_comment(1)

      assert.same({ "a.lua", 9 }, { where() })
      assert.equal(vim.log.levels.WARN, present(notes[1]).level)
    end)

    it("says when there are no comments", function()
      edit_file()

      reviewing.next_comment(1)

      assert.same({ { msg = "Changeset: no review comments in " .. dir, level = vim.log.levels.INFO } }, notes)
    end)
  end)

  describe("last_comment", function()
    it("opens the review comment saved last in its file, passing over drafts", function()
      edit_file()
      vim.fn.writefile(vim.split(("y"):rep(10, "\n"), "\n"), dir .. "/b.lua")
      comment_store.keep(dir, comment())
      comment_store.keep(dir, comment({ path = "b.lua", line = 3, body = "last" }))
      comment_store.keep(dir, comment({ line = 7, draft = true }))

      reviewing.last_comment()

      assert.equal(dir .. "/b.lua", vim.fs.normalize(vim.api.nvim_buf_get_name(0)))
      assert.equal(3, vim.api.nvim_win_get_cursor(0)[1])
      assert.equal("last", window().body)
    end)

    it("passes over a comment on a whole file", function()
      edit_file()
      comment_store.keep(dir, comment({ body = "last on a line" }))
      comment_store.keep(dir, { path = "a.lua", body = "the file" })

      reviewing.last_comment()

      assert.equal(4, vim.api.nvim_win_get_cursor(0)[1])
      assert.equal("last on a line", window().body)
    end)

    it("warns, naming its file, when the file of the comment saved last is gone", function()
      edit_file()
      comment_store.keep(dir, comment())
      comment_store.keep(dir, comment({ path = "gone.lua" }))

      reviewing.last_comment()

      assert.same({}, windows)
      assert.equal(vim.log.levels.WARN, present(notes[1]).level)
      assert.truthy((present(notes[1]).msg:find("gone.lua", 1, true)))
    end)

    it("says when no review comment is saved", function()
      edit_file()
      comment_store.keep(dir, comment({ draft = true }))

      reviewing.last_comment()

      assert.same({}, windows)
      assert.equal(vim.log.levels.INFO, present(notes[1]).level)
    end)

    it("refuses in a modified buffer", function()
      edit_file()
      comment_store.keep(dir, comment())
      vim.api.nvim_buf_set_lines(0, 0, 1, false, { "edited" })

      reviewing.last_comment()

      assert.same({}, windows)
      assert.equal(vim.log.levels.WARN, present(notes[1]).level)
    end)
  end)
end)
