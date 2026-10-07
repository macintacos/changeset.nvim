local changeset = require("changeset")
local comment_store = require("changeset.comment_store")
local blocks = require("changeset.review_comment_blocks")
local cursor = require("support.cursor")
local dialog = require("support.dialog")
local Fixture = require("support.git")
local Paths = require("changeset.paths")

describe("review comment blocks", function()
  local tmp, previous_dir

  before_each(function()
    tmp, previous_dir = Fixture.enter_tempdir()
    Fixture.init_repo("trunk", tmp)
    local lines = {}
    for i = 1, 40 do
      lines[i] = "alpha " .. i
    end
    vim.fn.writefile(lines, "alpha.txt")
    Fixture.commit("alpha", tmp)
    os.remove(comment_store.path())
    changeset.setup({ review_comment = { blocks = true } })
    blocks.show(true)
    vim.cmd.edit("alpha.txt")
  end)

  after_each(function()
    vim.cmd("silent! %bwipeout!")
    changeset.setup()
    blocks.show(false)
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
    os.remove(comment_store.path())
  end)

  ---@param comment changeset.ReviewComment
  local function keep(comment)
    comment_store.keep(Paths.root(0), comment)
  end

  ---Each block's lines as text, in buffer order, keyed by nothing: a list of { line = N, text = { ... } }.
  ---@return { line: integer, text: string[], hl: string[][] }[]
  local function drawn()
    local ns = vim.api.nvim_get_namespaces()["changeset.review_comment_blocks"]
    local out = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
      local text, hl = {}, {}
      for i, chunks in ipairs(mark[4].virt_lines or {}) do
        text[i] = table.concat(vim.tbl_map(function(chunk)
          return chunk[1]
        end, chunks))
        hl[i] = vim.tbl_map(function(chunk)
          return chunk[2]
        end, chunks)
      end
      out[#out + 1] = { line = mark[2] + 1, text = text, hl = hl }
    end
    return out
  end

  ---Presses `keys`, firing the `CursorMoved` a UI-less Neovim leaves out when they move the cursor.
  ---@param keys string
  local function press(keys)
    local before = vim.api.nvim_win_get_cursor(0)
    vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
    if not vim.deep_equal(before, vim.api.nvim_win_get_cursor(0)) then
      vim.api.nvim_exec_autocmds("CursorMoved", {})
    end
  end

  ---@param line integer
  local function go(line)
    -- By way of a far line, so the arrival is no one-line move.
    for _, at in ipairs({ line + 10, line }) do
      vim.api.nvim_win_set_cursor(0, { at, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", {})
    end
  end

  local function lnum()
    return vim.api.nvim_win_get_cursor(0)[1]
  end

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

  it("wraps a long line at word boundaries within the review comment window's measure", function()
    keep({ path = "alpha.txt", line = 3, body = ("word "):rep(40) })

    local text = drawn()[1].text
    assert.truthy(vim.fn.strdisplaywidth(text[1]) <= 72 + 2)
    assert.truthy(#text > 3)
    for i = 2, #text - 1 do
      assert.truthy(text[i]:find("^│ word"))
    end
  end)

  it("narrows to the narrowest window showing the buffer", function()
    keep({ path = "alpha.txt", line = 3, body = ("word "):rep(40) })
    vim.cmd("vsplit")
    vim.api.nvim_win_set_width(0, 40)
    vim.api.nvim_exec_autocmds("WinResized", {})

    local room = 40 - vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].textoff
    local width = vim.fn.strdisplaywidth(drawn()[1].text[1])
    assert.truthy(width <= room and width > room - 6)
  end)

  it("drops the end-of-line text of a comment drawn as a block, keeping its lit numbers", function()
    keep({ path = "alpha.txt", line = 3, body = "short" })

    local ns = vim.api.nvim_get_namespaces()["changeset.review_comments"]
    local mark = assert(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })[1][4])
    assert.is_nil(mark.virt_text)
    assert.are.equal("ChangesetReviewComment", mark.number_hl_group)
  end)

  it("draws a draft with a dashed border", function()
    keep({ path = "alpha.txt", line = 3, body = "short", draft = true })

    local text = drawn()[1].text
    assert.truthy(text[2]:find("^┆ short  *┆$"))
    assert.truthy(text[3]:find("┄"))
  end)

  it("stacks two blocks on one line", function()
    keep({ path = "alpha.txt", line = 3, body = "first" })
    keep({ path = "alpha.txt", line = 3, start_line = 2, body = "second" })

    local stack = drawn()
    assert.are.same({ 3, 3 }, { stack[1].line, stack[2].line })
    assert.is_true(stack[1].text[2] ~= stack[2].text[2])
  end)

  it("toggles between blocks and marks", function()
    keep({ path = "alpha.txt", line = 3, body = "short" })

    blocks.toggle()
    assert.are.same({}, drawn())

    blocks.toggle()
    assert.are.equal(1, #drawn())
  end)

  describe("landing", function()
    before_each(function()
      keep({ path = "alpha.txt", line = 3, body = "short" })
    end)

    ---The line and text of the block showing its keys.
    local function selected()
      for _, block in ipairs(drawn()) do
        if block.text[#block.text]:find("<CR> edit") then
          return block.line, block.text[2]
        end
      end
    end

    it("lands on the block with j from its line, then steps off onto the next line", function()
      go(3)

      press("j")
      assert.are.equal(3, lnum())
      assert.are.equal(3, selected())
      assert.truthy(cursor.hidden())

      press("j")
      assert.are.equal(4, lnum())
      assert.is_nil(selected())
      assert.is_false(cursor.hidden())
    end)

    it("lands on the block with k from the line under it, then steps up onto its line", function()
      go(4)

      press("k")
      assert.are.equal(4, lnum())
      assert.are.equal(3, selected())

      press("k")
      assert.are.equal(3, lnum())
      assert.is_nil(selected())
    end)

    it("goes back the way it came", function()
      go(3)
      press("j")
      press("k")
      assert.are.equal(3, lnum())

      go(4)
      press("k")
      press("j")
      assert.are.equal(4, lnum())
      assert.is_nil(selected())
    end)

    it("lands whatever j is mapped to", function()
      vim.keymap.set("n", "j", "gj")
      go(3)

      press("j")
      vim.keymap.del("n", "j")
      assert.are.equal(3, selected())
    end)

    it("moves past the block on a count", function()
      go(2)

      press("5j")
      assert.are.equal(7, lnum())
      assert.is_nil(selected())
    end)

    it("stops on each of two stacked blocks", function()
      keep({ path = "alpha.txt", line = 3, start_line = 2, body = "second" })
      go(3)

      press("j")
      local line, first = selected()
      assert.are.equal(3, line)
      press("j")
      local _, second = selected()
      assert.truthy(second)
      assert.is_true(first ~= second)
      press("j")
      assert.are.equal(4, lnum())
    end)

    it("deselects on <Esc> and gives back the keys it took", function()
      go(3)
      press("j")
      assert.are.equal("<Esc>", vim.fn.maparg("<Esc>", "n", false, true).lhs)

      press("<Esc>")
      assert.is_nil(selected())
      assert.are.same({}, vim.fn.maparg("<Esc>", "n", false, true))
      assert.are.same({}, vim.fn.maparg("d", "n", false, true))
    end)

    it("asks to delete the selected block's comment on d", function()
      go(3)
      press("j")

      press("d")
      assert.are.equal("Delete the review comment", dialog.title())
      dialog.press("D")
      assert.truthy(vim.wait(1000, function()
        return #comment_store.list(Paths.root(0)) == 0
      end))
    end)

    it("opens the selected block's comment for editing on <CR>", function()
      go(3)
      press("j")

      press("<CR>")
      local win = vim.api.nvim_get_current_win()
      assert.are.equal("short", vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)[1])
      vim.cmd("stopinsert")
    end)
  end)
end)
