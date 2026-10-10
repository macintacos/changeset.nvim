local Dialog = require("support.dialog")
local Fixture = require("support.git")
local comment_store = require("changeset.comment_store")
local review_comment_window = require("changeset.review_comment_window")

---@return integer?
local function float()
  return vim.iter(vim.api.nvim_list_wins()):find(function(win)
    return vim.api.nvim_win_get_config(win).relative ~= ""
  end)
end

local function closed()
  vim.wait(1000, function()
    return float() == nil
  end, 10)
  return float() == nil
end

-- A user's own insert-mode <C-g>s, as nvim-surround maps it, in place before the plugin's default keys are.
local surrounded = 0
vim.keymap.set("i", "<C-g>s", function()
  surrounded = surrounded + 1
end)

describe(":Changeset from the review comment window", function()
  local dir, source, echo, notify, notes

  before_each(function()
    if not vim.g.loaded_changeset then
      vim.cmd("runtime plugin/changeset.lua")
      -- The spec runs before startup ends, so the default keys wait for it.
      vim.api.nvim_exec_autocmds("VimEnter", { group = "changeset.plugin" })
    end
    os.remove(comment_store.path())
    echo = vim.api.nvim_echo
    vim.api.nvim_echo = function() end
    notify, notes = vim.notify, {}
    vim.notify = function(msg, level)
      table.insert(notes, { msg = msg, level = level, window_open = float() ~= nil })
    end
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    dir = vim.fs.normalize(assert(vim.uv.fs_realpath(dir)))
    Fixture.init_repo("main", dir)
    vim.fn.writefile(vim.split(("x"):rep(20, "\n"), "\n"), dir .. "/a.lua")
    vim.cmd.edit(dir .. "/a.lua")
    source = vim.api.nvim_get_current_win()
  end)

  after_each(function()
    vim.api.nvim_echo = echo
    vim.notify = notify
    vim.cmd("silent! fclose!")
    vim.cmd.stopinsert()
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(dir, "rf")
    os.remove(comment_store.path())
  end)

  ---Opens the window on line `lnum` and types `text` into it.
  local function write(lnum, text)
    vim.api.nvim_win_set_cursor(source, { lnum, 0 })
    vim.cmd(("%dChangeset comment new"):format(lnum))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { text })
  end

  it("keeps a draft, then runs the subcommand from the comment's line in the file", function()
    comment_store.keep(dir, { path = "a.lua", line = 3, body = "before" })
    comment_store.keep(dir, { path = "a.lua", line = 15, body = "after" })
    write(10, "typing")
    vim.api.nvim_win_set_cursor(source, { 1, 0 })

    vim.cmd("Changeset comment next")

    assert.is_true(closed())
    assert.equal(source, vim.api.nvim_get_current_win())
    assert.equal(15, vim.api.nvim_win_get_cursor(source)[1])
    assert.is_true(vim.iter(comment_store.list(dir)):any(function(comment)
      return comment.line == 10 and comment.draft == true and comment.body == "typing"
    end))
  end)

  ---Lets what an earlier spec scheduled, such as its draft notice, run, then forgets what was said.
  local function quiet()
    vim.wait(100)
    notes = {}
  end

  it("keeps the comment being edited as a draft on :Changeset comment draft, though unchanged", function()
    comment_store.keep(dir, { path = "a.lua", line = 4, body = "note" })
    vim.api.nvim_win_set_cursor(source, { 4, 0 })
    vim.cmd("4Changeset comment new")
    quiet()

    vim.cmd("Changeset comment draft")

    assert.is_true(closed())
    assert.same({ { path = "a.lua", line = 4, body = "note", draft = true } }, comment_store.list(dir))
    vim.wait(200)
    assert.same(
      { "Changeset: kept the review comment as a draft" },
      vim.tbl_map(function(note)
        return note.msg
      end, notes)
    )
  end)

  it("keeps changed text as a draft on :Changeset comment draft, saying so once", function()
    comment_store.keep(dir, { path = "a.lua", line = 4, body = "note" })
    vim.api.nvim_win_set_cursor(source, { 4, 0 })
    vim.cmd("4Changeset comment new")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "changed" })
    quiet()

    vim.cmd("Changeset comment draft")

    assert.is_true(closed())
    assert.same({ { path = "a.lua", line = 4, body = "changed", draft = true } }, comment_store.list(dir))
    vim.wait(200)
    assert.same(
      { "Changeset: kept the review comment as a draft" },
      vim.tbl_map(function(note)
        return note.msg
      end, notes)
    )
  end)

  it("keeps a new comment's text as a draft on :Changeset comment draft", function()
    write(4, "typed")

    vim.cmd("Changeset comment draft")

    assert.is_true(closed())
    assert.same({ { path = "a.lua", line = 4, body = "typed", draft = true } }, comment_store.list(dir))
  end)

  it("saves on :Changeset comment new", function()
    write(4, "note")

    vim.cmd("Changeset comment new")

    assert.is_true(closed())
    assert.same({ { path = "a.lua", line = 4, body = "note" } }, comment_store.list(dir))
  end)

  it("deletes a stored comment once the dialog confirms, keeping nothing", function()
    comment_store.keep(dir, { path = "a.lua", line = 4, body = "note" })
    write(4, "note edited")

    vim.cmd("Changeset comment del")
    assert.truthy(table.concat(Dialog.lines(), "\n"):find("note edited", 1, true))
    Dialog.press("D")

    assert.is_true(closed())
    assert.same({}, comment_store.list(dir))
  end)

  it("returns to the window, still writing, when the dialog keeps the comment", function()
    write(4, "unsaved")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_feedkeys(vim.keycode("A<Cmd>Changeset comment del<CR>"), "x!", false)
    assert(Dialog.win(), "no dialog open")
    local back
    -- "x!" holds the resumed insert mode open, unlike Dialog.press, until this ends it.
    vim.defer_fn(function()
      back = { win = vim.api.nvim_get_current_win(), mode = vim.api.nvim_get_mode().mode }
      vim.cmd.stopinsert()
    end, 200)
    vim.api.nvim_feedkeys("k", "x!", false)

    assert.same({ win = win, mode = "i" }, back)
    assert.same({}, comment_store.list(dir))
  end)

  it("closes a blank, unstored comment on delete without asking", function()
    write(4, "")

    vim.cmd("Changeset comment del")

    assert.is_true(closed())
    assert.same({}, comment_store.list(dir))
  end)

  it("closes the window first for a repeatable map pressed in it", function()
    write(4, "typing")
    vim.cmd.stopinsert()

    vim.api.nvim_feedkeys(vim.keycode("<Plug>(changeset-comment-next)"), "x", false)

    assert.is_true(closed())
    assert.equal(source, vim.api.nvim_get_current_win())
    assert.is_nil(review_comment_window.current())
  end)

  ---The window buffer's own insert-mode map for `lhs`, if any.
  local function insert_map(lhs)
    return vim.iter(vim.api.nvim_buf_get_keymap(0, "i")):find(function(keymap)
      return vim.keycode(keymap.lhs) == vim.keycode(lhs)
    end)
  end

  it("saves on <C-g>cc typed in insert mode", function()
    write(4, "")
    vim.api.nvim_feedkeys(vim.keycode("Anote<C-g>cc"), "x", false)

    assert.is_true(closed())
    assert.same({ { path = "a.lua", line = 4, body = "note" } }, comment_store.list(dir))
  end)

  it("runs keys typed straight after an insert-mode save in the file it returns to", function()
    write(4, "")
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(source), 0, -1, false)

    vim.api.nvim_feedkeys(vim.keycode("Anote<C-s>:15<CR><C-g>ccnext<C-s>"), "xt", false)

    assert.equal(source, vim.api.nvim_get_current_win())
    assert.same(lines, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(source), 0, -1, false))
    assert.same({
      { path = "a.lua", line = 4, body = "note" },
      { path = "a.lua", line = 15, body = "next" },
    }, comment_store.list(dir))
  end)

  it("asks to delete a saved comment saved blank before any key typed after the save", function()
    comment_store.keep(dir, { path = "a.lua", line = 4, body = "note" })
    write(4, "")
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(source), 0, -1, false)

    vim.api.nvim_feedkeys(vim.keycode("A<C-s>D"), "xt", false)

    assert.is_true(closed())
    assert.same(lines, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(source), 0, -1, false))
    assert.same({}, comment_store.list(dir))
  end)

  it("keeps the draft and runs keys typed straight after <S-Esc> in the file", function()
    write(4, "")
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(source), 0, -1, false)

    vim.api.nvim_feedkeys(vim.keycode("Atext<S-Esc>dd"), "xt", false)

    assert.is_true(closed())
    assert.same({ { path = "a.lua", line = 4, body = "text", draft = true } }, comment_store.list(dir))
    table.remove(lines, vim.api.nvim_win_get_cursor(source)[1])
    assert.same(lines, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(source), 0, -1, false))
  end)

  it("leaves a user's own insert-mode key under <C-g> to run in the window", function()
    comment_store.keep(dir, { path = "a.lua", line = 3, body = "saved" })
    write(4, "")
    assert.is_nil(insert_map("<C-g>s"))
    assert.truthy(insert_map("<C-g>cn"))
    vim.api.nvim_feedkeys(vim.keycode("Ahi<C-g>s<Esc>"), "x", false)

    assert.equal(1, surrounded)
    assert.equal(1, #comment_store.list(dir))
    assert.truthy(review_comment_window.current())
  end)

  it("leaves Vim's own insert-mode <C-g>j to move down a line in the window", function()
    write(4, "")

    vim.api.nvim_feedkeys(vim.keycode("ione<CR>two<Esc>gg0i<C-g>jX<Esc>"), "x", false)

    assert.truthy(review_comment_window.current())
    assert.same({ "one", "Xtwo" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end)

  it("hands keys typed ahead of <C-g>cd in insert mode to the delete dialog", function()
    write(4, "")
    vim.api.nvim_feedkeys(vim.keycode("Ahello world<C-g>cdD"), "x", false)

    assert.is_true(closed())
    assert.same({}, comment_store.list(dir))
  end)

  it("says it deleted the comment once the window has closed", function()
    comment_store.keep(dir, { path = "a.lua", line = 4, body = "note" })
    write(4, "note")
    vim.api.nvim_feedkeys(vim.keycode("A<C-g>cdD"), "x", false)

    assert.is_true(closed())
    local deleted = vim.iter(notes):find(function(note)
      return note.msg:find("deleted", 1, true)
    end)
    assert.is_false(assert(deleted).window_open)
  end)

  it("notifies that it kept a draft before running the subcommand", function()
    write(4, "typing")
    vim.api.nvim_feedkeys(vim.keycode("A<C-g>cn"), "x", false)

    assert.is_true(closed())
    vim.wait(200, function()
      return #notes > 0
    end, 10)
    assert.truthy(vim.iter(notes):find(function(note)
      return note.msg:find("draft", 1, true) and note.level == vim.log.levels.INFO
    end))
  end)

  it("takes a split of its buffer with it, keeping a draft", function()
    write(4, "typing")
    vim.cmd.stopinsert()
    vim.cmd.split()

    assert.is_true(closed())
    vim.wait(100)
    assert.equal(1, #vim.api.nvim_list_wins())
    assert.same({ { path = "a.lua", line = 4, body = "typing", draft = true } }, comment_store.list(dir))
  end)

  it("refuses to show another buffer", function()
    write(4, "typing")
    vim.cmd.stopinsert()
    local buf = vim.api.nvim_get_current_buf()

    pcall(vim.cmd.edit, dir .. "/a.lua")

    assert.equal(buf, vim.api.nvim_get_current_buf())
  end)

  it("describes its <C-g> keys under ? as they act on the comment being written", function()
    write(4, "")
    local function desc(lhs)
      local keymap = vim.iter(vim.api.nvim_buf_get_keymap(0, "n")):find(function(each)
        return vim.keycode(each.lhs) == vim.keycode(lhs)
      end)
      return keymap and keymap.desc
    end

    assert.equal("Save the review comment", desc("<C-g>cc"))
    assert.equal("Delete this review comment", desc("<C-g>cd"))
    assert.equal("Keep this review comment as a draft", desc("<C-g>ch"))
    assert.equal("Keep a draft, then: Next review comment", desc("<C-g>cn"))
  end)

  describe("comment last", function()
    it("stays on the comment saved last when it is the one being written, and says so", function()
      comment_store.keep(dir, { path = "a.lua", line = 3, body = "older" })
      comment_store.keep(dir, { path = "a.lua", line = 9, body = "last" })
      vim.api.nvim_win_set_cursor(source, { 9, 0 })
      vim.cmd("9Changeset comment new")
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "last, edited" })

      vim.cmd("Changeset comment last")

      assert.equal(win, vim.api.nvim_get_current_win())
      assert.equal("last", comment_store.list(dir)[2].body)
    end)

    it("closes the window on another comment, keeping a draft, and opens the comment saved last", function()
      comment_store.keep(dir, { path = "a.lua", line = 9, body = "last" })
      write(4, "typing")

      vim.cmd("Changeset comment last")

      vim.wait(500, function()
        local current = review_comment_window.current()
        return current ~= nil and current.comment.line == 9
      end, 10)
      assert.equal(9, assert(review_comment_window.current()).comment.line)
      assert.equal(9, vim.api.nvim_win_get_cursor(source)[1])
      assert.truthy(vim.iter(comment_store.list(dir)):find(function(comment)
        return comment.line == 4 and comment.draft
      end))
    end)
  end)

  it("leaves to the user an insert-mode key under <C-g> mapped after startup", function()
    local ran = 0
    vim.keymap.set("i", "<C-g>y", function()
      ran = ran + 1
    end)
    write(4, "")
    local mapped = insert_map("<C-g>y")
    vim.api.nvim_feedkeys(vim.keycode("Ahi<C-g>y<Esc>"), "x", false)
    vim.keymap.del("i", "<C-g>y")

    assert.is_nil(mapped)
    assert.equal(1, ran)
    assert.truthy(review_comment_window.current())
  end)

  it("lists under ? a key whose insert form the user took, as it acts in the window", function()
    write(4, "")
    local keymap = vim.iter(vim.api.nvim_buf_get_keymap(0, "n")):find(function(each)
      return vim.keycode(each.lhs) == vim.keycode("<C-g>s")
    end)

    assert.equal("Keep a draft, then: Submit the review to an agent", assert(keymap).desc)
  end)

  it("saves on a save key that is also a default <C-g> key", function()
    require("changeset.config").setup({ review_comment = { save = { "<C-g>y" } } })
    write(4, "")
    vim.api.nvim_feedkeys(vim.keycode("Ahi<C-g>y"), "x", false)
    require("changeset.config").setup()

    assert.is_true(closed())
    assert.same({ { path = "a.lua", line = 4, body = "hi" } }, comment_store.list(dir))
  end)

  it("goes on writing after an insert-mode key that leaves the window open", function()
    comment_store.keep(dir, { path = "a.lua", line = 9, body = "last" })
    vim.api.nvim_win_set_cursor(source, { 9, 0 })
    vim.cmd("9Changeset comment new")
    vim.api.nvim_feedkeys(vim.keycode("A more<C-g>clX<Esc>"), "x", false)

    assert.same({ "last moreX" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end)

  for _, key in ipairs({ "<C-g>cc", "<C-s>" }) do
    it(("goes on writing after a save on %s that fails"):format(key), function()
      write(4, "")
      vim.fn.writefile({ "[1,2]" }, comment_store.path())
      vim.api.nvim_feedkeys(vim.keycode("Atext" .. key .. "X<Esc>"), "x", false)
      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      os.remove(comment_store.path())

      assert.same({ "textX" }, lines)
    end)
  end

  it("notifies the draft after the subcommand's own message, so it replaces it", function()
    local said = {}
    vim.api.nvim_echo = function()
      table.insert(said, "echo")
    end
    vim.notify = function(msg)
      table.insert(said, msg:find("draft", 1, true) and "draft" or "other")
    end
    comment_store.keep(dir, { path = "a.lua", line = 15, body = "after" })
    write(4, "typing")
    vim.api.nvim_feedkeys(vim.keycode("A<C-g>cn"), "x", false)
    vim.wait(200, function()
      return vim.tbl_contains(said, "draft")
    end, 10)

    assert.equal("echo", said[1])
    assert.truthy(vim.tbl_contains(said, "draft"))
  end)

  ---The mode each message arrives in while `keys` are typed, insert mode held open until they have run.
  ---@param keys string
  ---@return string[]
  local function modes_said_in(keys)
    local modes = {}
    local function said()
      table.insert(modes, vim.api.nvim_get_mode().mode)
    end
    vim.api.nvim_echo, vim.notify = said, said
    vim.defer_fn(vim.cmd.stopinsert, 300)
    vim.api.nvim_feedkeys(vim.keycode(keys), "x!", false)
    return modes
  end

  it("says it is already editing the comment saved last once writing has picked back up", function()
    comment_store.keep(dir, { path = "a.lua", line = 9, body = "last" })
    vim.api.nvim_win_set_cursor(source, { 9, 0 })
    vim.cmd("9Changeset comment new")

    assert.same({ "i" }, modes_said_in("A<C-g>cl"))
  end)

  it("reports a failed save once writing has picked back up", function()
    write(4, "")
    vim.fn.writefile({ "[1,2]" }, comment_store.path())
    local modes = modes_said_in("Atext<C-g>cc")
    os.remove(comment_store.path())

    assert.same({ "i" }, modes)
  end)
end)
