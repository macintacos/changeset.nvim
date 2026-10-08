local Dialog = require("support.dialog")
local Fixture = require("support.git")
local Notify = require("support.notify")
local Paths = require("changeset.paths")
local comment_store = require("changeset.comment_store")

describe("changeset.review_handoff", function()
  local handoff, restore_notify, notes, windows, dir, tree, focused, echoes, echo

  before_each(function()
    os.remove(comment_store.path())
    windows, focused, tree = {}, false, nil
    echoes, echo = {}, vim.api.nvim_echo
    vim.api.nvim_echo = function(chunks)
      table.insert(echoes, chunks[1][1])
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
    package.loaded["changeset.review_handoff"] = nil
    handoff = require("changeset.review_handoff")
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

  describe("abandon", function()
    it("deletes drafts too, saying how many of the comments are drafts", function()
      edit_file()
      comment_store.keep(dir, comment())
      comment_store.keep(dir, comment({ line = 7, draft = true }))

      handoff.abandon()
      assert.truthy(table.concat(Dialog.lines(), " "):gsub("%s+", " "):find("1 is a draft", 1, true))
      reply("A", function()
        return #comment_store.list(dir) == 0
      end)

      assert.same({}, comment_store.list(dir))
    end)

    it("says there is no review, without asking", function()
      edit_file()

      handoff.abandon()

      assert.is_false(asking())
      assert.equal(vim.log.levels.INFO, notes[1].level)
    end)

    it("asks, counting the comments, then clears the repository's", function()
      edit_file()
      comment_store.keep(dir, comment())
      comment_store.keep(dir, comment({ line = 7 }))
      comment_store.keep("/other", comment())

      handoff.abandon()
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

      handoff.abandon()
      reply("A", function()
        return #comment_store.list("/tree/root") == 0
      end)

      assert.same({}, comment_store.list("/tree/root"))
    end)
  end)

  describe("submit", function()
    local sent, opts, answer

    before_each(function()
      sent, opts, answer = {}, nil, {}
      package.loaded["changeset.herdr"] = {
        send = function(text, o, cb)
          table.insert(sent, text)
          opts = o
          cb(answer[1], answer[2])
        end,
      }
    end)

    it("hands send the review, the buffer's unsaved lines included", function()
      edit_file()
      vim.api.nvim_buf_set_lines(0, 3, 4, false, { "unsaved" })
      comment_store.keep(dir, comment())

      handoff.submit()

      assert.equal(dir .. "/a.lua:4\n```lua\nunsaved\n```\nhi", sent[1])
    end)

    it("refuses a second submit while the first is being delivered, saying so", function()
      local held = {}
      package.loaded["changeset.herdr"] = {
        send = function(text, _, cb)
          table.insert(sent, text)
          table.insert(held, cb)
        end,
      }
      edit_file()
      comment_store.keep(dir, comment())

      handoff.submit()
      handoff.submit()
      held[1](nil, "claude")
      handoff.submit()

      assert.equal(1, #sent)
      assert.equal(vim.log.levels.INFO, notes[1].level)
      assert.truthy(notes[1].msg:find("already", 1, true))
      assert.equal(1, #assert(comment_store.submitted(dir)))
    end)

    it("titles the agent picker with what it sends, and ranks the agents by the repository", function()
      edit_file()
      comment_store.keep(dir, comment())
      comment_store.keep(dir, comment({ line = 7 }))

      handoff.submit()

      assert.same({ title = "Submit 2 review comments", root = dir }, opts)
    end)

    it("quotes an unloaded file from disk beside a loaded file whose name it prefixes", function()
      edit_file()
      vim.fn.writefile({ "js 1", "js 2", "js 3", "js 4" }, dir .. "/index.js")
      vim.fn.writefile({ "json 1", "json 2", "json 3", "json 4" }, dir .. "/index.json")
      vim.cmd.edit(dir .. "/index.json")
      comment_store.keep(dir, comment({ path = "index.js" }))

      handoff.submit()

      assert.equal(dir .. "/index.js:4\n```javascript\njs 4\n```\nhi", sent[1])
    end)

    it("warns that the sent comments are still listed when they can't be removed", function()
      edit_file()
      comment_store.keep(dir, comment())
      package.loaded["changeset.herdr"].send = function(_, _, cb)
        vim.fn.writefile({ "[1,2]" }, comment_store.path())
        cb(nil, "claude")
      end

      handoff.submit()

      os.remove(comment_store.path())
      assert.equal(vim.log.levels.WARN, notes[#notes].level)
    end)

    it("drops the fence for a file that is gone", function()
      edit_file()
      comment_store.keep(dir, comment({ path = "gone.lua" }))

      handoff.submit()

      assert.equal(dir .. "/gone.lua:4\nhi", sent[1])
    end)

    it("sends only saved comments, keeping the drafts and saying how many stay", function()
      edit_file()
      comment_store.keep(dir, comment())
      comment_store.keep(dir, comment({ line = 7, body = "draft", draft = true }))
      answer = { nil, "claude" }

      handoff.submit()

      assert.equal(dir .. "/a.lua:4\n```lua\nx\n```\nhi", sent[1])
      assert.same({ comment({ line = 7, body = "draft", draft = true }) }, comment_store.list(dir))
      assert.truthy(notes[#notes].msg:find("1 draft stays", 1, true), notes[#notes].msg)
    end)

    it("sends nothing with only drafts, counting them", function()
      edit_file()
      comment_store.keep(dir, comment({ draft = true }))

      handoff.submit()

      assert.same({}, sent)
      assert.truthy(notes[1].msg:find("1 draft", 1, true), notes[1].msg)
    end)

    it("removes only the sent comments once sent, and says where they went and how to get them back", function()
      edit_file()
      comment_store.keep(dir, comment())
      comment_store.keep(dir, comment({ line = 9, body = "as sent" }))
      package.loaded["changeset.herdr"].send = function(_, _, cb)
        comment_store.keep(dir, comment({ line = 7, body = "written meanwhile" }))
        comment_store.keep(dir, comment({ line = 9, body = "edited meanwhile" }))
        cb(nil, "claude")
      end

      handoff.submit()

      assert.same(
        { comment({ line = 7, body = "written meanwhile" }), comment({ line = 9, body = "edited meanwhile" }) },
        comment_store.list(dir)
      )
      assert.same({
        msg = "Changeset: submitted 2 review comments to claude; :Changeset review restore brings them back",
        level = vim.log.levels.INFO,
      }, notes[#notes])
    end)

    it("keeps what it sent for restore, with when and to whom", function()
      edit_file()
      comment_store.keep(dir, comment())
      answer = { nil, "claude" }
      local before = os.time()

      handoff.submit()

      local batch = assert(comment_store.submitted(dir))[1]
      assert.same({ comment() }, batch.comments)
      assert.equal("claude", batch.to)
      assert.is_true(batch.at >= before and batch.at <= os.time(), tostring(batch.at))
    end)

    it("keeps every comment and warns when sending fails", function()
      edit_file()
      comment_store.keep(dir, comment())
      answer = { "answer claude's prompt first" }

      handoff.submit()

      assert.same({ comment() }, comment_store.list(dir))
      assert.equal(vim.log.levels.WARN, notes[#notes].level)
      assert.truthy(notes[#notes].msg:find("answer claude's prompt first", 1, true))
    end)

    it("keeps every comment and says nothing on a cancelled pick", function()
      edit_file()
      comment_store.keep(dir, comment())

      handoff.submit()

      assert.same({ comment() }, comment_store.list(dir))
      assert.same({}, notes)
    end)

    it("sends nothing without comments", function()
      edit_file()

      handoff.submit()

      assert.same({}, sent)
      assert.equal(vim.log.levels.INFO, notes[1].level)
    end)
  end)

  describe("restore", function()
    local time = os.time

    before_each(function()
      package.loaded["changeset.herdr"] = {
        send = function(_, _, cb)
          cb(nil, "claude")
        end,
      }
      -- A minute between submits, as a user's take at least: a batch is known by when and to whom it went.
      local now = 0
      os.time = function()
        now = now + 60
        return now
      end
    end)

    after_each(function()
      os.time = time
    end)

    it("brings back the review comments submitted last, saying how many", function()
      edit_file()
      comment_store.keep(dir, comment())
      comment_store.keep(dir, comment({ line = 7 }))
      handoff.submit()

      handoff.restore()

      assert.same({ comment(), comment({ line = 7 }) }, comment_store.list(dir))
      assert.same({ msg = "Changeset: restored 2 review comments", level = vim.log.levels.INFO }, notes[#notes])
    end)

    it("says how many stay submitted for lines that hold a review comment written since", function()
      edit_file()
      comment_store.keep(dir, comment())
      comment_store.keep(dir, comment({ line = 7 }))
      handoff.submit()
      comment_store.keep(dir, comment({ body = "since" }))

      handoff.restore()

      assert.same({ comment({ body = "since" }), comment({ line = 7 }) }, comment_store.list(dir))
      assert.equal(
        "Changeset: restored 1 review comment; 1 stays submitted: its lines hold a newer one",
        notes[#notes].msg
      )
    end)

    it("says when every review comment submitted last stays submitted", function()
      edit_file()
      comment_store.keep(dir, comment())
      comment_store.keep(dir, comment({ line = 7 }))
      handoff.submit()
      comment_store.keep(dir, comment({ body = "since" }))
      comment_store.keep(dir, comment({ line = 7, body = "since" }))

      handoff.restore()

      assert.equal("Changeset: 2 review comments stay submitted: their lines hold newer ones", notes[#notes].msg)
    end)

    ---Submits two batches: a.lua:4 first, then a.lua:7.
    local function submit_twice()
      edit_file()
      comment_store.keep(dir, comment())
      handoff.submit()
      comment_store.keep(dir, comment({ line = 7, body = "second" }))
      handoff.submit()
    end

    it(
      "asks which batch to bring back when there are several, newest first, naming each one's first comment",
      function()
        submit_twice()

        handoff.restore()

        assert.equal("Restore submitted review comments", Dialog.title())
        local lines = Dialog.lines()
        assert.truthy(lines[1]:find("claude%s+1 review comment%s+a.lua:7  second"), lines[1])
        assert.truthy(lines[2]:find("a.lua:4  hi", 1, true), lines[2])
      end
    )

    it("names no time or agent for the batch a store kept before it kept several", function()
      edit_file()
      vim.fn.mkdir(vim.fs.dirname(comment_store.path()), "p")
      require("changeset.jsonfile").write(comment_store.path(), { submitted = { [dir] = { main = { comment() } } } })
      comment_store.keep(dir, comment({ line = 7, body = "second" }))
      handoff.submit()

      handoff.restore()

      local row = Dialog.lines()[2]
      assert.truthy(row:find("^%s*2%s+1 review comment%s+a.lua:4  hi"), row)
    end)

    it("brings back the batch picked, leaving the others", function()
      submit_twice()

      handoff.restore()
      reply("2", function()
        return #comment_store.list(dir) == 1
      end)

      assert.same({ comment() }, comment_store.list(dir))
      assert.equal(1, #assert(comment_store.submitted(dir)))
    end)

    it("brings back the batch picked though another submit landed while the picker was open", function()
      submit_twice()
      local file = vim.api.nvim_get_current_win()

      handoff.restore()
      comment_store.keep(dir, comment({ line = 9, body = "third" }))
      vim.api.nvim_win_call(file, handoff.submit)
      assert.equal(3, #assert(comment_store.submitted(dir)))
      reply("2", function()
        return #comment_store.list(dir) == 1
      end)

      assert.same({ comment() }, comment_store.list(dir))
    end)

    it("says when the batch picked is no longer submitted", function()
      submit_twice()

      handoff.restore()
      comment_store.restore(dir, assert(comment_store.submitted(dir))[2])
      reply("2", function()
        return notes[#notes].msg:find("no longer", 1, true) ~= nil
      end)

      assert.same({ comment() }, comment_store.list(dir))
      assert.truthy(notes[#notes].msg:find("that batch is no longer submitted", 1, true), notes[#notes].msg)
    end)

    it("brings back nothing on a cancelled pick", function()
      submit_twice()

      handoff.restore()
      reply("q", function()
        return not asking()
      end)

      assert.same({}, comment_store.list(dir))
      assert.equal(2, #assert(comment_store.submitted(dir)))
    end)

    it("says when there is nothing to restore", function()
      edit_file()

      handoff.restore()

      assert.same({}, comment_store.list(dir))
      assert.equal(vim.log.levels.INFO, notes[1].level)
      assert.truthy(notes[1].msg:find("no submitted review comments to restore", 1, true), notes[1].msg)
    end)

    it("reports a record it can't restore into", function()
      edit_file()
      vim.fn.mkdir(vim.fs.dirname(comment_store.path()), "p")
      vim.fn.writefile({ "[1,2]" }, comment_store.path())

      handoff.restore()

      os.remove(comment_store.path())
      assert.equal(vim.log.levels.ERROR, notes[1].level)
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

      handoff.list()

      local qf = vim.fn.getqflist({ title = 0, items = 0 })
      assert.equal("Changeset review comments", qf.title)
      local items = vim.tbl_map(function(item)
        return { item.lnum, item.end_lnum, item.text }
      end, qf.items)
      assert.same({ { 2, 3, "first" }, { 6, 6, "second …" } }, items)
      assert.equal(dir .. "/a.lua", vim.fs.normalize(vim.api.nvim_buf_get_name(qf.items[1].bufnr)))
    end)

    it("lists a whole file's comment as an item on no line, ahead of its lines'", function()
      edit_file()
      comment_store.keep(dir, comment({ line = 6, body = "a line" }))
      comment_store.keep(dir, { path = "a.lua", body = "the file" })

      handoff.list()

      local items = vim.tbl_map(function(item)
        return { item.lnum, item.end_lnum, item.text }
      end, vim.fn.getqflist())
      assert.same({ { 0, 0, "the file" }, { 6, 6, "a line" } }, items)
    end)

    it("marks a draft's item", function()
      edit_file()
      comment_store.keep(dir, comment({ body = "unsure", draft = true }))

      handoff.list()

      assert.equal("[draft] unsure", vim.fn.getqflist()[1].text)
    end)

    it("replaces its own list on a rerun rather than adding one", function()
      edit_file()
      comment_store.keep(dir, comment())
      vim.fn.setqflist({}, " ", { title = "other" })

      handoff.list()
      handoff.list()

      assert.equal(2, vim.fn.getqflist({ nr = "$" }).nr)
    end)

    it("says when there are no comments", function()
      edit_file()

      handoff.list()

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

        handoff.yank()

        assert.equal(
          require("changeset.review_text").text(dir, { comment() }, function()
            return { "x" }
          end),
          vim.fn.getreg('"')
        )
        assert.same({ comment() }, comment_store.list(dir))
        assert.equal(vim.log.levels.INFO, notes[1].level)
        assert.truthy(notes[1].msg:find('"', 1, true))
      end
    )

    it("copies only saved comments", function()
      vim.fn.has = function(feature)
        return feature == "clipboard" and 0 or has(feature)
      end
      edit_file()
      comment_store.keep(dir, comment())
      comment_store.keep(dir, comment({ line = 7, body = "draft", draft = true }))
      vim.fn.setreg('"', "")

      handoff.yank()

      assert.is_nil(vim.fn.getreg('"'):find("draft", 1, true))
      assert.truthy(vim.fn.getreg('"'):find("hi", 1, true))
      assert.truthy(notes[1].msg:find("1 draft left out", 1, true), notes[1].msg)
    end)

    it("copies nothing with only drafts, counting them", function()
      edit_file()
      comment_store.keep(dir, comment({ draft = true }))
      vim.fn.setreg('"', "")

      handoff.yank()

      assert.equal("", vim.fn.getreg('"'))
      assert.truthy(notes[1].msg:find("1 draft", 1, true), notes[1].msg)
    end)

    it("says when there is nothing to copy", function()
      edit_file()

      handoff.yank()

      assert.equal(vim.log.levels.INFO, notes[1].level)
    end)
  end)
end)
