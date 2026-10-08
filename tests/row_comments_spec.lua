local changeset = require("changeset")
local comment_store = require("changeset.comment_store")
local window = require("changeset.window")
local Changes = require("support.changes")
local CommentWindow = require("support.comment_window")
local Fixture = require("support.git")
local Notify = require("support.notify")
local Sidebar = require("support.sidebar")
local Symbols = require("support.symbols")

describe("a review comment from a symbol's or a change's row", function()
  local tmp, previous_dir, symbols, restore_notify, notes

  before_each(function()
    if not vim.g.loaded_changeset then
      vim.cmd("runtime plugin/changeset.lua")
    end
    tmp, previous_dir = Fixture.enter_tempdir()
    Fixture.feature({
      ["mod.lua"] = Fixture.numbered(10),
      ["other.lua"] = { "return 1" },
    }, {
      ["mod.lua"] = Fixture.numbered(10, { [2] = true, [3] = true, [8] = true }),
      ["other.lua"] = { "return 2" },
    }, tmp)
    os.remove(comment_store.path())
    symbols = Symbols.install()
    notes, restore_notify = Notify.capture()
  end)

  after_each(function()
    restore_notify()
    symbols.restore()
    vim.cmd("silent! fclose!")
    vim.cmd.stopinsert()
    changeset.close()
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
    os.remove(comment_store.path())
  end)

  ---Keeps `comments`, then opens the sidebar on mod.lua, its function `M.one` on lines 7-9, once the tree settles.
  ---@param comments changeset.ReviewComment[]?
  ---@return string root
  local function open_sidebar(comments)
    vim.cmd.edit("mod.lua")
    local root = require("changeset.paths").root(0)
    for _, comment in ipairs(comments or {}) do
      comment_store.keep(root, comment)
    end
    changeset.open()
    assert.is_true(vim.wait(10000, function()
      return #symbols.asks > 0
    end, 25))
    for _, path in ipairs(symbols.asks[1].paths) do
      symbols.asks[1].answer(path, path == "mod.lua" and { Changes.sym("M.one", "Function", 0, 7, 9) } or {})
    end
    Sidebar.settle()
    return root
  end

  ---Types `text` into the window and presses its first save key, as typed in insert mode.
  ---@param win integer
  ---@param text string
  local function save(win, text)
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(win), 0, -1, false, { text })
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_feedkeys(vim.keycode("a<C-s>"), "x", false)
  end

  ---Puts the sidebar's cursor on the row containing `text`, answering its line.
  ---@param text string
  ---@return integer
  local function cursor_to(text)
    Sidebar.cursor_to(text)
    return vim.api.nvim_win_get_cursor(0)[1]
  end

  it("is written on a symbol's line in a window under its row", function()
    local root = open_sidebar()
    local lnum = cursor_to("M.one")

    vim.cmd("Changeset comment new")

    local win = assert(CommentWindow.find())
    assert.equal(window.win(), vim.api.nvim_win_get_config(win).win)
    assert.same({ lnum - 1, 0 }, vim.api.nvim_win_get_config(win).bufpos)
    assert.truthy(CommentWindow.title(win):find("line 7", 1, true))
    save(win, "why?")
    assert.same({ { path = "mod.lua", line = 7, body = "why?" } }, comment_store.list(root))
  end)

  it("is written on a change's lines in a window under its row", function()
    local root = open_sidebar()
    local lnum = cursor_to("L2–3")

    vim.cmd("Changeset comment new")

    local win = assert(CommentWindow.find())
    assert.same({ lnum - 1, 0 }, vim.api.nvim_win_get_config(win).bufpos)
    assert.truthy(CommentWindow.title(win):find("lines 2-3", 1, true))
    save(win, "both?")
    assert.same({ { path = "mod.lua", line = 3, start_line = 2, body = "both?" } }, comment_store.list(root))
  end)

  it("opens the comment already on a change's lines to edit", function()
    open_sidebar({ { path = "mod.lua", line = 3, start_line = 2, body = "already" } })
    local lnum = cursor_to("L2–3")

    vim.cmd("Changeset comment new")

    local win = assert(CommentWindow.find())
    assert.same({ lnum - 1, 0 }, vim.api.nvim_win_get_config(win).bufpos)
    assert.equal("already", CommentWindow.text(win))
  end)

  it("opens the narrowest comment covering a symbol's line to edit, as from the file", function()
    open_sidebar({
      { path = "mod.lua", line = 10, start_line = 6, body = "wide" },
      { path = "mod.lua", line = 9, start_line = 7, body = "narrow" },
    })
    cursor_to("M.one")

    vim.cmd("Changeset comment new")

    assert.equal("narrow", CommentWindow.text(assert(CommentWindow.find())))
  end)

  it("is written on the line an Other changes row opens, its first change's first", function()
    local root = open_sidebar()
    cursor_to("Other changes")

    vim.cmd("Changeset comment new")

    save(assert(CommentWindow.find()), "here?")
    assert.same({ { path = "mod.lua", line = 2, body = "here?" } }, comment_store.list(root))
  end)

  it("opens the comment a Comments row lists to edit, under the row", function()
    open_sidebar({
      { path = "mod.lua", line = 9, start_line = 7, body = "listed" },
      { path = "mod.lua", line = 7, body = "narrower" },
    })
    local lnum = cursor_to("mod.lua:7-9")

    vim.cmd("Changeset comment new")

    local win = assert(CommentWindow.find())
    assert.same({ lnum - 1, 0 }, vim.api.nvim_win_get_config(win).bufpos)
    assert.equal("listed", CommentWindow.text(win))
  end)

  it("keeps a draft and the sidebar's cursor on its row when another subcommand runs from its window", function()
    local root = open_sidebar()
    cursor_to("M.one")
    vim.cmd("Changeset comment new")
    local win = assert(CommentWindow.find())
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(win), 0, -1, false, { "unsure" })

    vim.cmd("Changeset comment toggle")
    vim.cmd("Changeset comment toggle")

    assert.is_true(vim.wait(2000, function()
      return #comment_store.list(root) == 1
    end, 10))
    assert.same({ { path = "mod.lua", line = 7, body = "unsure", draft = true } }, comment_store.list(root))
    assert.truthy(Sidebar.cursor_line():find("M.one", 1, true))
  end)

  it("switches the comment a Comments row lists between saved and draft", function()
    local listed = { path = "mod.lua", line = 9, start_line = 7, body = "listed" }
    local root = open_sidebar({ listed })
    cursor_to("mod.lua:7-9")

    vim.cmd("Changeset comment draft")
    assert.same({ vim.tbl_extend("force", listed, { draft = true }) }, comment_store.list(root))
    vim.cmd("Changeset comment draft")

    assert.same({ listed }, comment_store.list(root))
  end)

  it("switches the whole file's comment from the file's row", function()
    local root = open_sidebar({ { path = "mod.lua", body = "the file" } })
    cursor_to("Implementation")
    vim.fn.search("mod\\.lua", "W")

    vim.cmd("Changeset comment draft")

    assert.same({ { path = "mod.lua", body = "the file", draft = true } }, comment_store.list(root))
  end)

  it("refuses on a section's header", function()
    open_sidebar()
    cursor_to("Implementation")

    vim.cmd("Changeset comment new")

    assert.is_nil(CommentWindow.find())
    assert.equal(1, #Notify.messages(notes, vim.log.levels.WARN))
  end)

  it("refuses while its file has unsaved edits", function()
    open_sidebar()
    vim.api.nvim_buf_set_lines(vim.fn.bufnr(tmp .. "/mod.lua"), 0, 0, false, { "new" })
    cursor_to("L2–3")

    vim.cmd("Changeset comment new")

    assert.is_nil(CommentWindow.find())
    assert.equal(1, #Notify.messages(notes, vim.log.levels.WARN))
  end)
end)
