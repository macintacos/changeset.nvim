local Fixture = require("support.git")
local comment_store = require("changeset.comment_store")

describe("changeset.reviewing", function()
  local reviewing, notify, notes, prompts, confirmed, windows, dir, tree, focused

  ---The options of the window opened last.
  local function window()
    return assert(windows[#windows], "no review comment window opened")
  end

  before_each(function()
    os.remove(comment_store.path())
    notes, prompts, windows, confirmed, focused, tree = {}, {}, {}, false, false, nil
    notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notes, { msg = msg, level = level })
    end
    package.loaded["changeset.confirm"] = {
      ask = function(question, yes)
        table.insert(prompts, question)
        if confirmed then
          yes()
        end
      end,
    }
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
    for _, name in ipairs({ "changeset.confirm", "changeset.review_comment_window", "changeset.window" }) do
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
      confirmed = true

      reviewing.open(comment())
      window().keep("")
      assert.same({}, prompts)
      vim.wait(100, function()
        return #prompts > 0
      end)

      assert.equal(1, #prompts)
      assert.same({}, comment_store.list(dir))
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

      assert.same({}, prompts)
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
    it("deletes the comment once confirmed", function()
      edit_file()
      comment_store.keep(dir, comment())
      confirmed = true

      reviewing.ask_delete(comment())

      assert.equal(1, #prompts)
      assert.same({}, comment_store.list(dir))
    end)

    it("keeps the comment when declined", function()
      edit_file()
      comment_store.keep(dir, comment())

      reviewing.ask_delete(comment())

      assert.same({ comment() }, comment_store.list(dir))
    end)
  end)

  describe("abandon", function()
    it("says there is no review, without asking", function()
      edit_file()

      reviewing.abandon()

      assert.same({}, prompts)
      assert.equal(vim.log.levels.INFO, notes[1].level)
    end)

    it("asks, counting the comments, then clears the repository's", function()
      edit_file()
      comment_store.keep(dir, comment())
      comment_store.keep(dir, comment({ line = 7 }))
      comment_store.keep("/other", comment())
      confirmed = true

      reviewing.abandon()

      assert.truthy(prompts[1]:find("2", 1, true))
      assert.same({}, comment_store.list(dir))
      assert.same({ comment() }, comment_store.list("/other"))
    end)

    it("abandons the tree's repository from the sidebar", function()
      comment_store.keep("/tree/root", comment())
      tree, focused, confirmed = { root = "/tree/root" }, true, true

      reviewing.abandon()

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
end)
