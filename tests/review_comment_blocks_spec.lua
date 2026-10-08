local changeset = require("changeset")
local comment_store = require("changeset.comment_store")
local review_comments = require("changeset.review_comments")
local cursor = require("support.cursor")
local dialog = require("support.dialog")
local Fixture = require("support.git")
local Paths = require("changeset.paths")

describe("review comment blocks", function()
  local tmp, previous_dir
  local columns = vim.o.columns

  before_each(function()
    tmp, previous_dir = Fixture.enter_tempdir()
    Fixture.init_repo("trunk", tmp)
    vim.fn.writefile(Fixture.numbered(40, nil, "alpha"), "alpha.txt")
    Fixture.commit("alpha", tmp)
    os.remove(comment_store.path())
    changeset.setup({ review_comment = { blocks = true } })
    vim.cmd.edit("alpha.txt")
  end)

  after_each(function()
    vim.cmd("silent! only")
    vim.cmd("silent! %bwipeout!")
    vim.cmd("silent! nunmap j")
    vim.cmd("silent! nunmap Q")
    vim.o.cursorline = false
    vim.o.columns = columns
    if not review_comments.shown() then
      review_comments.show(true)
    end
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
    os.remove(comment_store.path())
  end)

  ---@param comment changeset.ReviewComment
  local function keep(comment)
    comment_store.keep(Paths.root(0), comment)
  end

  ---Each extmark's lines as text, in buffer order, of `buf` or the current buffer.
  ---@param buf integer?
  ---@return { line: integer, text: string[] }[]
  local function drawn(buf)
    local ns = vim.api.nvim_get_namespaces()["changeset.review_comment_blocks"]
    local out = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf or 0, ns, 0, -1, { details = true })) do
      local text = {}
      for i, chunks in ipairs(mark[4].virt_lines or {}) do
        text[i] = table.concat(vim.tbl_map(function(chunk)
          return chunk[1]
        end, chunks))
      end
      out[#out + 1] = { line = mark[2] + 1, text = text }
    end
    return out
  end

  ---The first words of each body row, top first.
  ---@param text string[]
  ---@return string[]
  local function bodies(text)
    local out = {}
    for _, row in ipairs(text) do
      out[#out + 1] = row:match("^│ (%a+)")
    end
    return out
  end

  ---@param keys string
  local function press(keys)
    vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
  end

  local function lnum()
    return vim.api.nvim_win_get_cursor(0)[1]
  end

  ---@param line integer
  local function go(line)
    vim.api.nvim_win_set_cursor(0, { line, 0 })
  end

  ---The parked block's line and its body's first word.
  ---@return integer?, string?
  local function parked()
    for _, mark in ipairs(drawn()) do
      for i, row in ipairs(mark.text) do
        if row:find("<CR> edit", 1, true) then
          local top = i
          while not vim.startswith(mark.text[top], "╭") do
            top = top - 1
          end
          return mark.line, mark.text[top + 1]:match("^%S+ (%a+)")
        end
      end
    end
  end

  it("starts showing blocks when setup() asks for them", function()
    keep({ path = "alpha.txt", line = 3, body = "short" })

    assert.is_true(review_comments.shown())
    assert.are.equal(1, #drawn())
  end)

  it("draws a one-line comment as a box three lines tall under its last line, titled with its lines", function()
    keep({ path = "alpha.txt", line = 3, body = "short" })

    local block = drawn()[1]
    assert.are.equal(3, block.line)
    assert.are.equal(3, #block.text)
    assert.truthy(block.text[1]:find("^╭ Review comment · line 3 ─"))
    assert.truthy(block.text[2]:find("^│ short  *│$"))
    assert.truthy(vim.startswith(block.text[3], "╰─") and vim.endswith(block.text[3], "─╯"))
  end)

  it("fits the box to its title when the text is shorter", function()
    keep({ path = "alpha.txt", line = 5, start_line = 4, body = "ok" })

    local text = drawn()[1].text
    assert.are.equal(vim.fn.strdisplaywidth(text[1]), vim.fn.strdisplaywidth(text[2]))
    assert.truthy(text[1]:find("^╭ Review comment · lines 4%-5 ─╮$"))
  end)

  it("draws every row of a tab-indented snippet as wide as its border", function()
    keep({ path = "alpha.txt", line = 3, body = "try:\n\tif x then\n\t\ty()\n\tend" })

    local text = drawn()[1].text
    for i = 2, #text do
      assert.are.equal(vim.fn.strdisplaywidth(text[1]), vim.fn.strdisplaywidth(text[i]), text[i])
    end
  end)

  it("keeps the first line's indentation, as it keeps the lines after it", function()
    keep({ path = "alpha.txt", line = 3, body = "    foo()\n    bar()" })

    local text = drawn()[1].text
    assert.truthy(text[2]:find("^│     foo%(%)"), text[2])
    assert.truthy(text[3]:find("^│     bar%(%)"), text[3])
  end)

  it("wraps a long line at word boundaries within the review comment window's measure", function()
    keep({ path = "alpha.txt", line = 3, body = ("word "):rep(40) })

    local text = drawn()[1].text
    assert.truthy(vim.fn.strdisplaywidth(text[1]) <= 72 + 2)
    assert.truthy(#text > 3)
    for i = 2, #text - 1 do
      assert.truthy(text[i]:find("^│ word"))
    end
  end)

  it("draws a long comment's box as wide as the review comment window that edits it", function()
    vim.o.columns = 200
    keep({ path = "alpha.txt", line = 3, body = ("x"):rep(300) })
    local box = vim.fn.strdisplaywidth(drawn()[1].text[1])

    local win = require("changeset.review_comment_window").open({
      line = 10,
      title = "line 10",
      save_desc = "Save",
      close_desc = "Close",
      keys = { "<C-s>" },
      save = function() end,
      keep = function() end,
      back = function() end,
      comment = { path = "alpha.txt", line = 10, body = "" },
    })
    local width = vim.api.nvim_win_get_width(win)
    vim.api.nvim_win_close(win, true)
    vim.cmd.stopinsert()

    -- +2 for the window's border, which its width leaves out.
    assert.are.equal(box, width + 2)
  end)

  it("narrows to the narrowest window showing the buffer, cutting the title rather than the box", function()
    vim.cmd("vsplit")
    vim.api.nvim_win_set_width(0, 24)
    keep({ path = "alpha.txt", line = 3, body = ("word "):rep(40) })

    local room = 24 - vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].textoff
    local text = drawn()[1].text
    assert.are.equal(room, vim.fn.strdisplaywidth(text[1]))
    assert.are.equal(room, vim.fn.strdisplaywidth(text[2]))
    assert.truthy(text[1]:find("…", 1, true))
  end)

  it("narrows as a window showing the buffer is resized narrower", function()
    keep({ path = "alpha.txt", line = 3, body = ("word "):rep(40) })
    vim.cmd("vsplit")
    vim.api.nvim_win_set_width(0, 24)

    -- Neovim fires WinResized only as it redraws, which a spec never does.
    vim.api.nvim_exec_autocmds("WinResized", {})

    local room = 24 - vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].textoff
    assert.are.equal(room, vim.fn.strdisplaywidth(drawn()[1].text[1]))
  end)

  it("narrows to the text area as the gutter widens", function()
    vim.o.columns = 50
    vim.wo.number = false
    keep({ path = "alpha.txt", line = 3, body = ("word "):rep(40) })

    vim.wo.number = true
    -- Neovim fires no OptionSet before startup ends, which is when specs run.
    vim.api.nvim_exec_autocmds("OptionSet", { pattern = "number" })

    local win = vim.api.nvim_get_current_win()
    local room = vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
    assert.is_true(vim.fn.strdisplaywidth(drawn()[1].text[1]) <= room)
  end)

  it("drops the end-of-line text of a comment drawn as a block, keeping its lit numbers", function()
    keep({ path = "alpha.txt", line = 3, body = "short" })

    local ns = vim.api.nvim_get_namespaces()["changeset.review_comments"]
    local mark = assert(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })[1][4])
    assert.is_nil(mark.virt_text)
    assert.are.equal("ChangesetReviewComment", mark.number_hl_group)
  end)

  it("draws a draft with a dashed border in the draft colour, titled as a draft", function()
    keep({ path = "alpha.txt", line = 3, body = "short", draft = true })

    local text = drawn()[1].text
    assert.truthy(text[1]:find("^╭ Draft review comment · line 3 ┄"))
    assert.truthy(text[2]:find("^┆ short  *┆$"))
    assert.truthy(text[3]:find("┄"))
    local ns = vim.api.nvim_get_namespaces()["changeset.review_comment_blocks"]
    local top = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })[1][4].virt_lines[1]
    assert.are.same({ "ChangesetBlockDraft", "ChangesetBlockDraft" }, { top[1][2], top[2][2] })
  end)

  it("stacks two blocks on one line in the order the store lists them", function()
    keep({ path = "alpha.txt", line = 3, body = "first" })
    keep({ path = "alpha.txt", line = 3, start_line = 2, body = "second" })

    local marks = drawn()
    assert.are.equal(1, #marks)
    assert.are.same({ "first", "second" }, bodies(marks[1].text))
  end)

  it("toggles between blocks and marks", function()
    keep({ path = "alpha.txt", line = 3, body = "short" })

    review_comments.toggle()
    assert.are.same({}, drawn())

    review_comments.toggle()
    assert.are.equal(1, #drawn())
  end)

  it("forgets the blocks of a buffer unloaded under them", function()
    keep({ path = "alpha.txt", line = 3, body = "short" })
    local alpha = vim.api.nvim_get_current_buf()
    vim.cmd.enew()

    vim.cmd.bdelete(alpha)
    vim.cmd("vsplit")
    vim.api.nvim_win_set_width(0, 30)
    vim.cmd.redraw()
  end)

  it("lands through the user's own expr map, and leaves a count to it", function()
    vim.cmd([[nnoremap <expr> j v:count == 0 ? 'gj' : 'j']])
    keep({ path = "alpha.txt", line = 3, body = "short" })
    go(3)

    press("j")
    assert.are.equal(3, parked())

    press("<Esc>2j")
    assert.are.equal(5, lnum())
  end)

  ---What `run` returns with blocks hidden and then shown, each from the file as committed.
  ---@param run fun(): any
  ---@return any hidden
  ---@return any shown
  local function both_ways(run)
    review_comments.toggle()
    vim.cmd("silent edit!")
    local hidden = run()
    review_comments.toggle()
    vim.cmd("silent edit!")
    return hidden, run()
  end

  ---@return string[]
  local function buffer_lines()
    return vim.api.nvim_buf_get_lines(0, 0, -1, false)
  end

  it("lets a failing j end a macro, as without blocks", function()
    keep({ path = "alpha.txt", line = 3, body = "short" })
    vim.fn.setreg("q", "A;" .. vim.keycode("<Esc>") .. "j")

    local hidden, shown = both_ways(function()
      go(38)
      press("20@q")
      return buffer_lines()
    end)
    assert.are.same(hidden, shown)
  end)

  it("lets a failing j end the mapping that pressed it, as without blocks", function()
    keep({ path = "alpha.txt", line = 3, body = "short" })
    vim.cmd("nmap Q jdd")

    local hidden, shown = both_ways(function()
      go(40)
      press("Q")
      return #buffer_lines()
    end)
    assert.are.same(hidden, shown)
  end)

  it("lets a replayed macro move past blocks, as without blocks", function()
    keep({ path = "alpha.txt", line = 3, body = "short" })
    vim.fn.setreg("a", "A;" .. vim.keycode("<Esc>") .. "j")

    local hidden, shown = both_ways(function()
      go(1)
      press("5@a")
      return buffer_lines()
    end)
    assert.are.same(hidden, shown)
  end)

  it("parks for a typed j, never for one a mapping sends", function()
    keep({ path = "alpha.txt", line = 3, body = "short" })
    vim.cmd("nmap Q j")
    go(2)

    press("Q")
    press("Q")
    assert.are.equal(4, lnum())
    assert.is_nil(parked())
  end)

  it("lets <C-o>j from insert mode move past a block", function()
    keep({ path = "alpha.txt", line = 3, body = "short" })
    go(3)

    press("i<C-o>jX<Esc>")
    assert.are.equal("Xalpha 4", vim.api.nvim_buf_get_lines(0, 3, 4, false)[1])
  end)

  it("runs a global map of j made after the blocks were drawn", function()
    keep({ path = "alpha.txt", line = 3, body = "short" })
    vim.keymap.set("n", "j", function()
      vim.g.changeset_spec_j = true
      return "j"
    end, { expr = true })
    go(10)

    press("j")
    assert.is_true(vim.g.changeset_spec_j)
    vim.g.changeset_spec_j = nil
  end)

  it("leaves a buffer-local map of j made after the blocks were drawn", function()
    keep({ path = "alpha.txt", line = 3, body = "short" })
    vim.keymap.set("n", "j", "<Nop>", { buffer = 0, desc = "later" })

    review_comments.toggle()
    assert.are.equal("later", vim.fn.maparg("j", "n", false, true).desc)
    review_comments.toggle()
  end)

  it("keeps the column a move started from after stepping off a block", function()
    vim.api.nvim_buf_set_lines(0, 3, 6, false, { ("x"):rep(60), "short", ("y"):rep(60) })
    vim.cmd("silent write")
    keep({ path = "alpha.txt", line = 4, body = "short" })
    vim.api.nvim_win_set_cursor(0, { 4, 40 })

    press("jjj")
    assert.are.same({ 6, 40 }, vim.api.nvim_win_get_cursor(0))
  end)

  it("steps off a block parked from a short line to the column the move started at", function()
    vim.api.nvim_buf_set_lines(0, 3, 6, false, { ("x"):rep(60), "short", ("y"):rep(60) })
    vim.cmd("silent write")
    keep({ path = "alpha.txt", line = 5, body = "short" })
    vim.api.nvim_win_set_cursor(0, { 4, 40 })

    press("jjj")
    assert.are.same({ 6, 40 }, vim.api.nvim_win_get_cursor(0))
  end)

  it("gives a window split while parked the cursorline the parked one had", function()
    keep({ path = "alpha.txt", line = 3, body = "short" })
    vim.o.cursorline = true
    go(3)
    press("j")

    vim.cmd("split")
    assert.is_true(vim.wo.cursorline)
    vim.cmd("wincmd p")
    assert.is_true(vim.wo.cursorline)
  end)

  it("gives a buffer its own map of j back when blocks hide", function()
    vim.keymap.set("n", "j", "<Nop>", { buffer = 0, desc = "mine" })
    keep({ path = "alpha.txt", line = 3, body = "short" })
    assert.are.equal("Move, stopping on review comment blocks", vim.fn.maparg("j", "n", false, true).desc)

    review_comments.toggle()
    assert.are.equal("mine", vim.fn.maparg("j", "n", false, true).desc)
    review_comments.toggle()
  end)

  it("hides a line's blocks while the review comment window is open on it", function()
    keep({ path = "alpha.txt", line = 3, body = "short" })
    keep({ path = "alpha.txt", line = 6, body = "other" })
    local alpha = vim.api.nvim_get_current_buf()
    go(3)

    press("j<CR>")
    assert.are.same(
      { 6 },
      vim.tbl_map(
        function(mark)
          return mark.line
        end,
        vim.tbl_filter(function(mark)
          return #mark.text > 0
        end, drawn(alpha))
      )
    )

    press("q")
    assert.are.equal(2, #vim.tbl_filter(function(mark)
      return #mark.text > 0
    end, drawn()))
  end)

  it("resumes a draft from its parked block", function()
    keep({ path = "alpha.txt", line = 3, body = "half done", draft = true })
    go(3)

    press("j<CR>")
    assert.are.equal("half done", vim.api.nvim_get_current_line())
    assert.truthy(vim.inspect(vim.api.nvim_win_get_config(0).title):find("draft", 1, true))
    press("q")
  end)

  for _, keys in ipairs({ "<Esc><Esc>", "<Esc>q", "<Esc><S-Esc>", "<S-Esc>" }) do
    it(("parks on the comment's own block when %s closes its window"):format(keys), function()
      keep({ path = "alpha.txt", start_line = 2, line = 3, body = "range" })
      keep({ path = "alpha.txt", line = 3, body = "short" })
      local alpha = vim.api.nvim_get_current_buf()
      go(3)
      press("jj<CR>")

      press("A more" .. keys)
      -- From insert mode the window closes once insert mode has ended, a loop iteration later.
      vim.wait(1000, function()
        return parked() ~= nil
      end)
      assert.are.equal(alpha, vim.api.nvim_get_current_buf())
      assert.are.same({ 3, "short" }, { parked() })
      assert.truthy(cursor.hidden())
      assert.truthy(vim.iter(comment_store.list(Paths.root(0))):find(function(comment)
        return comment.body == "short more" and comment.draft
      end))
    end)
  end

  describe("stepping up onto a wrapped line", function()
    before_each(function()
      vim.api.nvim_buf_set_lines(0, 4, 6, false, { ("word "):rep(20), ("text "):rep(20) })
      vim.cmd("silent write")
      keep({ path = "alpha.txt", line = 5, body = "short" })
      vim.cmd("vsplit")
      vim.api.nvim_win_set_width(0, 40)
    end)

    ---Whether the cursor is on the last screen row of line 5.
    local function on_last_row_of_5()
      local line5 = vim.fn.getline(5)
      local pos = vim.api.nvim_win_get_cursor(0)
      return pos[1] == 5 and vim.fn.screenpos(0, 5, pos[2] + 1).row == vim.fn.screenpos(0, 5, #line5).row
    end

    it("lands on its last screen row from the end of the line under it", function()
      vim.api.nvim_win_set_cursor(0, { 6, 0 })
      press("$kk")
      assert.is_true(on_last_row_of_5())
      press("k")
      assert.is_true(vim.api.nvim_win_get_cursor(0)[1] <= 5 and not on_last_row_of_5())
    end)

    it("lands on its last screen row from a far column", function()
      vim.keymap.set("n", "k", "gk")
      vim.cmd.edit()
      vim.api.nvim_win_set_cursor(0, { 6, 30 })
      press("kk")
      assert.is_true(on_last_row_of_5())
      press("k")
      assert.are.equal(5, vim.api.nvim_win_get_cursor(0)[1])
      vim.keymap.del("n", "k")
    end)
  end)

  it("lets a split made long after letting go copy the window's own cursorline", function()
    keep({ path = "alpha.txt", line = 3, body = "short" })
    vim.o.cursorline = true
    go(3)
    press("j<Esc>")
    vim.wait(20)

    vim.wo.cursorline = false
    vim.cmd("split")
    assert.is_false(vim.wo.cursorline)
  end)

  describe("landing", function()
    before_each(function()
      keep({ path = "alpha.txt", line = 3, body = "short" })
    end)

    it("lands on the block with j from its line, then steps off onto the next line", function()
      go(3)

      press("j")
      assert.are.equal(3, lnum())
      assert.are.equal(3, parked())
      assert.truthy(cursor.hidden())

      press("j")
      assert.are.equal(4, lnum())
      assert.is_nil(parked())
      assert.is_false(cursor.hidden())
    end)

    it("lands on the block with k from the line under it, then steps up onto its line", function()
      go(4)

      press("k")
      assert.are.equal(4, lnum())
      assert.are.equal(3, parked())

      press("k")
      assert.are.equal(3, lnum())
      assert.is_nil(parked())
    end)

    it("goes back the way it came", function()
      go(3)
      press("jk")
      assert.are.equal(3, lnum())

      go(4)
      press("kj")
      assert.are.equal(4, lnum())
      assert.is_nil(parked())
    end)

    it("keeps the column it parked from", function()
      vim.api.nvim_win_set_cursor(0, { 4, 3 })

      press("kk")
      assert.are.same({ 3, 3 }, vim.api.nvim_win_get_cursor(0))
    end)

    it("moves past the block on a count", function()
      go(2)

      press("5j")
      assert.are.equal(7, lnum())
      assert.is_nil(parked())
    end)

    it("parks nothing for a jump of one line", function()
      go(4)

      press(":3<CR>")
      assert.are.equal(3, lnum())
      assert.is_nil(parked())
    end)

    it("parks nothing on leaving insert mode a line away", function()
      go(3)

      press("otyped<Esc>")
      assert.are.equal(4, lnum())
      assert.is_nil(parked())
    end)

    it("extends a Visual selection past the block", function()
      go(3)

      press("Vj")
      assert.are.equal(4, lnum())
      assert.is_nil(parked())
      press("<Esc>")
    end)

    it("leaves the cursor where p and u put it", function()
      ---The lines the cursor is on after `p`, then after `u`, from line 3.
      local function paste_and_undo()
        go(3)
        press("yyp")
        local pasted = lnum()
        press("u")
        return { pasted, lnum() }
      end
      review_comments.toggle()
      local native = paste_and_undo()
      review_comments.toggle()

      assert.are.same(native, paste_and_undo())
      assert.is_nil(parked())
    end)

    it("lets go on a key the block doesn't take", function()
      go(3)
      press("j")

      press("zz")
      vim.wait(100, function()
        return parked() == nil
      end)
      assert.is_nil(parked())
    end)

    it("stops on each of two stacked blocks, top first, both ways", function()
      keep({ path = "alpha.txt", line = 3, start_line = 2, body = "second" })
      go(3)

      press("j")
      assert.are.same({ 3, "short" }, { parked() })
      press("j")
      assert.are.same({ 3, "second" }, { parked() })
      press("k")
      assert.are.same({ 3, "short" }, { parked() })
      press("jj")
      assert.are.equal(4, lnum())
      press("k")
      assert.are.same({ 3, "second" }, { parked() })
    end)

    it("walks a stack under the first line and one under the last", function()
      keep({ path = "alpha.txt", line = 1, body = "top" })
      keep({ path = "alpha.txt", line = 40, body = "bottom" })
      go(1)
      press("j")
      assert.are.same({ 1, "top" }, { parked() })
      press("k")
      assert.are.equal(1, lnum())
      assert.is_nil(parked())

      go(40)
      press("j")
      assert.are.same({ 40, "bottom" }, { parked() })
      press("j")
      assert.are.equal(40, lnum())
      assert.is_nil(parked())
    end)

    it("steps off onto a closed fold next to the block", function()
      vim.cmd("4,6fold")
      go(3)

      press("jj")
      assert.are.equal(4, vim.fn.foldclosed(lnum()))

      press("k")
      assert.are.equal(3, parked())
      press("k")
      assert.are.equal(3, lnum())
    end)

    it("passes a block a closed fold hides", function()
      vim.cmd("2,3fold")
      go(2)

      press("j")
      assert.are.equal(4, lnum())
      assert.is_nil(parked())

      press("k")
      assert.are.equal(2, vim.fn.foldclosed(lnum()))
      assert.is_nil(parked())
    end)

    it("parks where the block sits after unsaved edits, and won't edit it then", function()
      vim.api.nvim_buf_set_lines(0, 0, 0, false, { "new" })
      go(4)

      press("j")
      assert.are.equal(4, parked())

      press("<CR>")
      assert.are.equal(4, parked())
    end)

    it("shows the parked block whole with nowrap without moving the cursor", function()
      vim.wo.wrap = false
      vim.api.nvim_buf_set_text(0, 2, 7, 2, 7, { ("x"):rep(500) })
      go(4)
      vim.cmd("normal! zt")

      press("k")
      assert.are.equal(4, lnum())
      assert.are.same({ 4, 3 }, { vim.fn.winsaveview().topline, vim.fn.winsaveview().topfill })
    end)

    it("shows the parked block whole above virtual lines over the next line, as gitsigns' deleted lines", function()
      local other = vim.api.nvim_create_namespace("spec.deleted_lines")
      local deleted = { { { "deleted 1" } }, { { "deleted 2" } } }
      vim.api.nvim_buf_set_extmark(0, other, 3, 0, { virt_lines = deleted, virt_lines_above = true })
      go(4)
      vim.cmd("normal! zt")

      press("k")
      assert.are.equal(4, lnum())
      assert.are.same({ 4, 5 }, { vim.fn.winsaveview().topline, vim.fn.winsaveview().topfill })
    end)

    it("keeps a parked block parked when its buffer's windows resize", function()
      go(3)
      press("j")

      vim.api.nvim_open_win(0, false, { split = "left", width = 30 })
      assert.are.equal(3, parked())
      assert.truthy(vim.fn.strdisplaywidth(drawn()[1].text[1]) <= 30)
    end)

    it("hides cursorline only in its own window", function()
      vim.o.cursorline = true
      go(3)

      press("j")
      assert.is_false(vim.wo.cursorline)
      assert.is_true(vim.go.cursorline)
      press("<Esc>")
      vim.o.cursorline = false
    end)

    it("gives back the keys it took", function()
      go(3)
      press("j")
      assert.are.equal("<Esc>", vim.fn.maparg("<Esc>", "n", false, true).lhs)

      press("<Esc>")
      assert.is_nil(parked())
      assert.are.same({}, vim.fn.maparg("<Esc>", "n", false, true))
      assert.are.same({}, vim.fn.maparg("d", "n", false, true))
    end)

    it("asks to delete the parked block's comment on d", function()
      go(3)
      press("j")

      press("d")
      assert.are.equal("Delete the review comment", dialog.title())
      dialog.press("D")
      assert.truthy(vim.wait(1000, function()
        return #comment_store.list(Paths.root(0)) == 0
      end))
    end)

    it("opens the parked block's comment for editing on <CR>", function()
      go(3)
      press("j")

      press("<CR>")
      local win = vim.api.nvim_get_current_win()
      assert.are.equal("short", vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)[1])
      vim.cmd("stopinsert")
    end)
  end)
end)
