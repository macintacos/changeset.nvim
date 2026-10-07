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

describe(":Changeset from the review comment window", function()
  local dir, source, echo

  before_each(function()
    if not vim.g.loaded_changeset then
      vim.cmd("runtime plugin/changeset.lua")
      -- The spec runs before startup ends, so the default keys wait for it.
      vim.api.nvim_exec_autocmds("VimEnter", { group = "changeset.plugin" })
    end
    os.remove(comment_store.path())
    echo = vim.api.nvim_echo
    vim.api.nvim_echo = function() end
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
    vim.cmd("silent! fclose!")
    vim.cmd.stopinsert()
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(dir, "rf")
    os.remove(comment_store.path())
  end)

  ---Opens the window on line `lnum` and types `text` into it.
  local function write(lnum, text)
    vim.api.nvim_win_set_cursor(source, { lnum, 0 })
    vim.cmd(("%dChangeset comment"):format(lnum))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { text })
  end

  it("keeps a draft, then runs the subcommand from the comment's line in the file", function()
    comment_store.keep(dir, { path = "a.lua", line = 3, body = "before" })
    comment_store.keep(dir, { path = "a.lua", line = 15, body = "after" })
    write(10, "typing")
    vim.api.nvim_win_set_cursor(source, { 1, 0 })

    vim.cmd("Changeset next-comment")

    assert.is_true(closed())
    assert.equal(source, vim.api.nvim_get_current_win())
    assert.equal(15, vim.api.nvim_win_get_cursor(source)[1])
    assert.is_true(vim.iter(comment_store.list(dir)):any(function(comment)
      return comment.line == 10 and comment.draft == true and comment.body == "typing"
    end))
  end)

  it("saves on :Changeset comment", function()
    write(4, "note")

    vim.cmd("Changeset comment")

    assert.is_true(closed())
    assert.same({ { path = "a.lua", line = 4, body = "note" } }, comment_store.list(dir))
  end)

  it("deletes a stored comment once the dialog confirms, keeping nothing", function()
    comment_store.keep(dir, { path = "a.lua", line = 4, body = "note" })
    write(4, "note edited")

    vim.cmd("Changeset delete")
    assert.truthy(table.concat(Dialog.lines(), "\n"):find("note edited", 1, true))
    Dialog.press("D")

    assert.is_true(closed())
    assert.same({}, comment_store.list(dir))
  end)

  it("returns to the window, still writing, when the dialog keeps the comment", function()
    write(4, "unsaved")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_feedkeys(vim.keycode("A<Cmd>Changeset delete<CR>"), "x!", false)
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

    vim.cmd("Changeset delete")

    assert.is_true(closed())
    assert.same({}, comment_store.list(dir))
  end)

  it("closes the window first for a repeatable map pressed in it", function()
    write(4, "typing")
    vim.cmd.stopinsert()

    vim.api.nvim_feedkeys(vim.keycode("<Plug>(changeset-next-comment)"), "x", false)

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

  it("leaves a default key the plugin didn't map unmapped in insert mode", function()
    local taken = vim.fn.maparg("<C-g>y", "n", false, true)
    vim.keymap.set("n", "<C-g>y", "<Nop>")
    write(4, "")
    local yank = insert_map("<C-g>y")
    vim.keymap.del("n", "<C-g>y")
    if next(taken) then
      vim.fn.mapset(taken)
    end

    assert.is_nil(yank)
    assert.truthy(insert_map("<C-g>cn"))
  end)
end)
