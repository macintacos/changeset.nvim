local Dialog = require("support.dialog")
local Fixture = require("support.git")
local comment_store = require("changeset.comment_store")

describe("changeset.reviewing", function()
  local reviewing, notify, notes, windows, dir, tree, focused

  ---The options of the window opened last.
  local function window()
    return assert(windows[#windows], "no review comment window opened")
  end

  before_each(function()
    os.remove(comment_store.path())
    notes, windows, focused, tree = {}, {}, false, nil
    notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notes, { msg = msg, level = level })
    end
    package.loaded["changeset.review_comment_window"] = {
      open = function(opts)
        table.insert(windows, opts)
      end,
    }
    package.loaded["changeset.window"] = {
      is_focused = function()
        return focused
      end,
    }
    package.loaded["changeset.build"] = {
      current = function()
        return tree
      end,
    }
    package.loaded["changeset.reviewing"] = nil
    reviewing = require("changeset.reviewing")
    dir = vim.fn.tempname()
  end)

  after_each(function()
    vim.notify = notify
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(dir, "rf")
    vim.cmd("silent! fclose!")
    for _, name in ipairs({ "changeset.review_comment_window", "changeset.window" }) do
      package.loaded[name] = nil
    end
    package.loaded["changeset.build"] = nil
    package.loaded["changeset.herdr"] = nil
  end)

  ---Opens `a.lua`, ten lines long, in a fresh repository.
  local function edit_file()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    dir = vim.fs.normalize(assert(vim.uv.fs_realpath(dir)))
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
  local function comment(fields)
    return vim.tbl_extend("force", { path = "a.lua", line = 4, body = "hi" }, fields or {})
  end

  describe("comment", function()
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

    it("keeps the text of a window closed without saving", function()
      edit_file()

      reviewing.comment(4, 4)
      window().keep("typed")

      assert.same({ comment({ body = "typed" }) }, comment_store.list(dir))
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
      assert.equal(vim.log.levels.WARN, notes[1].level)
    end)

    it("keeps the window open when the comment can't be stored", function()
      edit_file()
      vim.fn.mkdir(vim.fs.dirname(comment_store.path()), "p")
      vim.fn.writefile({ "[1,2]" }, comment_store.path())

      reviewing.comment(4, 4)
      local err
      window().save("lost?", function(e)
        err = e
      end)

      os.remove(comment_store.path())
      assert.truthy(err)
      assert.equal(vim.log.levels.ERROR, notes[1].level)
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
      assert.equal(vim.log.levels.WARN, notes[1].level)
      assert.truthy(notes[1].msg:find("Changeset: ", 1, true))
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

      local err
      window().save("new", function(e)
        err = e
      end)

      os.remove(comment_store.path())
      assert.truthy(err)
    end)

    it("drops an edit closed without saving, and says so", function()
      edit_file()
      comment_store.keep(dir, comment())

      reviewing.open(comment())
      window().keep("changed")

      assert.same({ comment() }, comment_store.list(dir))
      assert.equal(vim.log.levels.INFO, notes[1].level)
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

    it("says when the line has no comment", function()
      edit_file()
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      reviewing.delete()

      assert.equal(vim.log.levels.INFO, notes[1].level)
    end)

    it("refuses in a modified buffer", function()
      edit_file()
      comment_store.keep(dir, comment())
      vim.api.nvim_win_set_cursor(0, { 4, 0 })
      vim.api.nvim_buf_set_lines(0, 0, 0, false, { "new" })

      reviewing.delete()

      assert.equal(vim.log.levels.WARN, notes[1].level)
      assert.same({ comment() }, comment_store.list(dir))
    end)
  end)

  describe("ask_delete", function()
    it("asks about the comment by its place and its words", function()
      edit_file()
      comment_store.keep(dir, comment({ start_line = 3, body = "first\nsecond" }))

      reviewing.ask_delete(comment({ start_line = 3, body = "first\nsecond" }))

      local lines = table.concat(Dialog.lines(), "\n")
      assert.truthy(lines:find("a.lua:3-4", 1, true))
      assert.truthy(lines:find("▎ first\n%s*▎ second"))
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

  describe("abandon", function()
    it("says there is no review, without asking", function()
      edit_file()

      reviewing.abandon()

      assert.is_false(asking())
      assert.equal(vim.log.levels.INFO, notes[1].level)
    end)

    it("asks, counting the comments, then clears the repository's", function()
      edit_file()
      comment_store.keep(dir, comment())
      comment_store.keep(dir, comment({ line = 7 }))
      comment_store.keep("/other", comment())

      reviewing.abandon()
      assert.truthy(table.concat(Dialog.lines(), " "):find("2", 1, true))
      reply("A", function()
        return #comment_store.list(dir) == 0
      end)

      assert.same({}, comment_store.list(dir))
      assert.same({ comment() }, comment_store.list("/other"))
    end)

    it("abandons the tree's repository from the sidebar", function()
      comment_store.keep("/tree/root", comment())
      tree, focused = { root = "/tree/root" }, true

      reviewing.abandon()
      reply("A", function()
        return #comment_store.list("/tree/root") == 0
      end)

      assert.same({}, comment_store.list("/tree/root"))
    end)
  end)

  describe("_review_text", function()
    ---@param path string
    ---@param first integer
    ---@param last integer
    local function read(path, first, last)
      if path == "gone.lua" then
        return nil
      end
      local out = {}
      for n = first, last do
        out[#out + 1] = path .. " " .. n
      end
      return out
    end

    it("writes one block per comment by path, then line, with the lines fenced in the file's language", function()
      local text = reviewing._review_text({
        { path = "b.lua", line = 2, body = "second" },
        { path = "a.lua", line = 9, body = "later" },
        { path = "a.lua", line = 4, start_line = 3, body = "first\n\n" },
      }, read)

      assert.equal(
        table.concat({
          "a.lua:3-4",
          "```lua",
          "a.lua 3",
          "a.lua 4",
          "```",
          "first",
          "",
          "a.lua:9",
          "```lua",
          "a.lua 9",
          "```",
          "later",
          "",
          "b.lua:2",
          "```lua",
          "b.lua 2",
          "```",
          "second",
        }, "\n"),
        text
      )
    end)

    it("fences lines holding a fence with one more backtick than their longest run", function()
      local text = reviewing._review_text({ { path = "a.md", line = 2, start_line = 1, body = "b" } }, function()
        return { "````lua", "x" }
      end)

      assert.equal("a.md:1-2\n`````markdown\n````lua\nx\n`````\nb", text)
    end)

    it("leaves the fence's language empty for a file type it can't tell", function()
      local text = reviewing._review_text({ { path = "notes.zzqq", line = 1, body = "b" } }, read)

      assert.equal("notes.zzqq:1\n```\nnotes.zzqq 1\n```\nb", text)
    end)

    it("writes no fence when the lines can't be read", function()
      assert.equal("gone.lua:5\nwhy", reviewing._review_text({ { path = "gone.lua", line = 5, body = "why" } }, read))
    end)
  end)

  describe("submit", function()
    local sent, answer

    before_each(function()
      sent, answer = {}, {}
      package.loaded["changeset.herdr"] = {
        send = function(text, cb)
          table.insert(sent, text)
          cb(answer[1], answer[2])
        end,
      }
    end)

    it("hands send the review, the buffer's unsaved lines included", function()
      edit_file()
      vim.api.nvim_buf_set_lines(0, 3, 4, false, { "unsaved" })
      comment_store.keep(dir, comment())

      reviewing.submit()

      assert.equal("a.lua:4\n```lua\nunsaved\n```\nhi", sent[1])
    end)

    it("quotes an unloaded file from disk beside a loaded file whose name it prefixes", function()
      edit_file()
      vim.fn.writefile({ "js 1", "js 2", "js 3", "js 4" }, dir .. "/index.js")
      vim.fn.writefile({ "json 1", "json 2", "json 3", "json 4" }, dir .. "/index.json")
      vim.cmd.edit(dir .. "/index.json")
      comment_store.keep(dir, comment({ path = "index.js" }))

      reviewing.submit()

      assert.equal("index.js:4\n```javascript\njs 4\n```\nhi", sent[1])
    end)

    it("warns that the sent comments are still listed when they can't be removed", function()
      edit_file()
      comment_store.keep(dir, comment())
      package.loaded["changeset.herdr"].send = function(_, cb)
        vim.fn.writefile({ "[1,2]" }, comment_store.path())
        cb(nil, "claude")
      end

      reviewing.submit()

      os.remove(comment_store.path())
      assert.equal(vim.log.levels.WARN, notes[#notes].level)
    end)

    it("drops the fence for a file that is gone", function()
      edit_file()
      comment_store.keep(dir, comment({ path = "gone.lua" }))

      reviewing.submit()

      assert.equal("gone.lua:4\nhi", sent[1])
    end)

    it("removes only the sent comments once sent, and says who got them", function()
      edit_file()
      comment_store.keep(dir, comment())
      comment_store.keep(dir, comment({ line = 9, body = "as sent" }))
      package.loaded["changeset.herdr"].send = function(_, cb)
        comment_store.keep(dir, comment({ line = 7, body = "written meanwhile" }))
        comment_store.keep(dir, comment({ line = 9, body = "edited meanwhile" }))
        cb(nil, "claude")
      end

      reviewing.submit()

      assert.same(
        { comment({ line = 7, body = "written meanwhile" }), comment({ line = 9, body = "edited meanwhile" }) },
        comment_store.list(dir)
      )
      assert.equal(vim.log.levels.INFO, notes[#notes].level)
      assert.truthy(notes[#notes].msg:find("claude", 1, true))
    end)

    it("keeps every comment and warns when sending fails", function()
      edit_file()
      comment_store.keep(dir, comment())
      answer = { "answer claude's prompt first" }

      reviewing.submit()

      assert.same({ comment() }, comment_store.list(dir))
      assert.equal(vim.log.levels.WARN, notes[#notes].level)
      assert.truthy(notes[#notes].msg:find("answer claude's prompt first", 1, true))
    end)

    it("keeps every comment and says nothing on a cancelled pick", function()
      edit_file()
      comment_store.keep(dir, comment())

      reviewing.submit()

      assert.same({ comment() }, comment_store.list(dir))
      assert.same({}, notes)
    end)

    it("sends nothing without comments", function()
      edit_file()

      reviewing.submit()

      assert.same({}, sent)
      assert.equal(vim.log.levels.INFO, notes[1].level)
    end)
  end)

  describe("next_comment and prev_comment", function()
    local echoed, echo

    before_each(function()
      echoed, echo = {}, vim.api.nvim_echo
      vim.api.nvim_echo = function(chunks)
        table.insert(echoed, chunks[1][1])
      end
    end)

    after_each(function()
      vim.api.nvim_echo = echo
    end)

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
      assert.equal("review comment 2 of 3", echoed[1])

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
      assert.matches("review comment 3 of 3.*wrapped", echoed[2])
    end)

    it("wraps past the last comment to the first", function()
      three_comments()
      vim.cmd.edit(dir .. "/b.lua")
      vim.api.nvim_win_set_cursor(0, { 3, 0 })

      reviewing.next_comment(1)

      assert.same({ "a.lua", 2 }, { where() })
      assert.matches("wrapped", echoed[1])
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
      package.loaded["changeset.window"].commit = function(...)
        table.insert(committed, { ... })
        return true
      end

      reviewing.next_comment(1)

      assert.same({ { dir .. "/a.lua", 2, "reuse" } }, committed)
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
      assert(ok, err)
      assert.equal(vim.log.levels.WARN, notes[1].level)
    end)

    it("steps over as many comments as its count", function()
      three_comments()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      reviewing.next_comment(2)
      assert.same({ "a.lua", 4 }, { where() })
      reviewing.prev_comment(3)
      assert.same({ "a.lua", 4 }, { where() })
      assert.equal("review comment 2 of 3, wrapped", echoed[#echoed])
    end)

    it("keeps focus where it was when it refuses the file window before it", function()
      three_comments()
      vim.api.nvim_buf_set_lines(0, 0, 0, false, { "new" })
      vim.cmd("new")
      vim.bo.buftype = "nofile"
      local scratch_win = vim.api.nvim_get_current_win()

      reviewing.next_comment(1)

      assert.equal(scratch_win, vim.api.nvim_get_current_win())
      assert.equal(vim.log.levels.WARN, notes[1].level)
      vim.api.nvim_buf_delete(0, { force = true })
    end)

    it("refuses in a modified buffer", function()
      three_comments()
      vim.api.nvim_buf_set_lines(0, 0, 0, false, { "new" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      reviewing.next_comment(1)

      assert.same({ "a.lua", 1 }, { where() })
      assert.equal(vim.log.levels.WARN, notes[1].level)
    end)

    it("refuses when the comment's file has unsaved edits", function()
      three_comments()
      vim.cmd.edit(dir .. "/b.lua")
      vim.api.nvim_buf_set_lines(0, 0, 0, false, { "new" })
      vim.cmd("hide edit " .. dir .. "/a.lua")
      vim.api.nvim_win_set_cursor(0, { 9, 0 })

      reviewing.next_comment(1)

      assert.same({ "a.lua", 9 }, { where() })
      assert.equal(vim.log.levels.WARN, notes[1].level)
    end)

    it("says when there are no comments", function()
      edit_file()

      reviewing.next_comment(1)

      assert.same({ { msg = "Changeset: no review comments in " .. dir, level = vim.log.levels.INFO } }, notes)
    end)
  end)

  describe("list", function()
    after_each(function()
      vim.cmd("silent! cclose")
      vim.fn.setqflist({}, "f")
    end)

    it("fills the quickfix list in order, each item's lines and the body's first line", function()
      edit_file()
      comment_store.keep(dir, comment({ line = 6, body = "second\nmore" }))
      comment_store.keep(dir, comment({ start_line = 2, line = 3, body = "first" }))

      reviewing.list()

      local qf = vim.fn.getqflist({ title = 0, items = 0 })
      assert.equal("Changeset review comments", qf.title)
      local items = vim.tbl_map(function(item)
        return { item.lnum, item.end_lnum, item.text }
      end, qf.items)
      assert.same({ { 2, 3, "first" }, { 6, 6, "second …" } }, items)
      assert.equal(dir .. "/a.lua", vim.fs.normalize(vim.api.nvim_buf_get_name(qf.items[1].bufnr)))
    end)

    it("replaces its own list on a rerun rather than adding one", function()
      edit_file()
      comment_store.keep(dir, comment())
      vim.fn.setqflist({}, " ", { title = "other" })

      reviewing.list()
      reviewing.list()

      assert.equal(2, vim.fn.getqflist({ nr = "$" }).nr)
    end)

    it("says when there are no comments", function()
      edit_file()

      reviewing.list()

      assert.equal(vim.log.levels.INFO, notes[1].level)
    end)
  end)

  describe("yank", function()
    local has

    before_each(function()
      has = vim.fn.has
    end)

    after_each(function()
      vim.fn.has = has
    end)

    it(
      "copies the review text to the unnamed register without a clipboard, saying so, and keeps the comments",
      function()
        vim.fn.has = function(feature)
          return feature == "clipboard" and 0 or has(feature)
        end
        edit_file()
        comment_store.keep(dir, comment())
        vim.fn.setreg('"', "")

        reviewing.yank()

        assert.equal(
          reviewing._review_text({ comment() }, function()
            return { "x" }
          end),
          vim.fn.getreg('"')
        )
        assert.same({ comment() }, comment_store.list(dir))
        assert.equal(vim.log.levels.INFO, notes[1].level)
        assert.truthy(notes[1].msg:find('"', 1, true))
      end
    )

    it("says when there is nothing to copy", function()
      edit_file()

      reviewing.yank()

      assert.equal(vim.log.levels.INFO, notes[1].level)
    end)
  end)
end)
