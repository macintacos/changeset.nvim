local Dialog = require("support.dialog")
local present = require("support.present")
local dialog = require("changeset.dialog")

---Waits for a scheduled answer, or a moment for one that never comes.
---@param answered fun(): boolean
local function settle(answered)
  vim.wait(200, answered, 10)
end

describe("changeset.dialog", function()
  local opener ---@type integer

  before_each(function()
    vim.cmd("silent! only")
    opener = vim.api.nvim_get_current_win()
  end)

  after_each(function()
    vim.cmd("silent! fclose!")
    vim.cmd("silent! %bwipeout!")
  end)

  describe("confirm", function()
    ---@type boolean
    local confirmed

    ---@param opts changeset.ConfirmOpts?
    local function ask(opts)
      confirmed = false
      dialog.confirm(
        opts
          or { title = "Abandon the review", body = { { text = "Deletes all 3 review comments." } }, action = "Abandon" },
        function()
          confirmed = true
        end
      )
      assert.not_nil(Dialog.win(), "no dialog opened")
    end

    ---@param keys string
    ---@return boolean confirmed
    local function answer(keys)
      Dialog.press(keys)
      settle(function()
        return confirmed
      end)
      return confirmed
    end

    it("keeps on a <CR> pressed straight away, as focus starts on Keep", function()
      ask()

      assert.is_false(answer("<CR>"))
      assert.equal(opener, vim.api.nvim_get_current_win())
    end)

    it("draws Keep and the action as buttons under the body", function()
      ask()

      local lines = Dialog.lines()
      assert.truthy((present(lines[#lines - 1]):find("Keep%s+Abandon$")))
      assert.equal("Abandon the review", Dialog.title())
    end)

    for _, case in ipairs({
      { keys = "A", confirms = true },
      { keys = "k", confirms = false },
      { keys = "aA", confirms = true },
      { keys = "l<CR>", confirms = true },
      { keys = "<Tab><CR>", confirms = true },
      { keys = "<Right><Space>", confirms = true },
      { keys = "<S-Tab><CR>", confirms = true },
      { keys = "lh<CR>", confirms = false },
      { keys = "l<Left><CR>", confirms = false },
      { keys = "<Tab><Tab><CR>", confirms = false },
      { keys = "lq", confirms = false },
      { keys = "l<Esc>", confirms = false },
    }) do
      it(("%s %s"):format(case.confirms and "confirms on" or "keeps on", case.keys), function()
        ask()

        assert.equal(case.confirms, answer(case.keys))
        assert.equal(opener, vim.api.nvim_get_current_win())
      end)
    end

    it("stays open, without a word, on the action's letter typed without Shift, as a `dd` would", function()
      ask()
      vim.v.errmsg = ""

      answer("a")

      assert.is_false(confirmed)
      assert.truthy(Dialog.win())
      assert.equal("", vim.v.errmsg)
    end)

    it("presses a button clicked with the mouse", function()
      ask()

      Dialog.click("Abandon")
      settle(function()
        return confirmed
      end)

      assert.is_true(confirmed)
    end)

    it("ignores a click between the buttons", function()
      ask()

      Dialog.click("    Abandon")
      settle(function()
        return confirmed
      end)

      assert.is_false(confirmed)
      assert.truthy(Dialog.win())
    end)

    it("keeps when its window is left any other way, and returns focus to where it opened", function()
      vim.cmd.split()
      local other = vim.api.nvim_get_current_win()
      vim.api.nvim_set_current_win(opener)
      ask()

      vim.api.nvim_set_current_win(other)
      settle(function()
        return confirmed
      end)

      assert.is_false(confirmed)
      assert.equal(opener, vim.api.nvim_get_current_win())
      assert.same(
        {},
        vim.tbl_filter(function(win)
          return vim.api.nvim_win_get_config(win).relative ~= ""
        end, vim.api.nvim_list_wins())
      )
    end)

    ---Whether any float is open.
    ---@return boolean
    local function floating()
      return vim.iter(vim.api.nvim_list_wins()):any(function(win)
        return vim.api.nvim_win_get_config(win).relative ~= ""
      end)
    end

    -- `%s` stands for a file the opener showed before, which the float's jumplist and alternate file hold.
    for _, keys in ipairs({ "<C-o>", "<C-^>", ":edit %s<CR>", ":buffer %s<CR>" }) do
      it(("keeps its own buffer on %s, so it stays to be answered"):format(keys), function()
        local file = vim.fn.tempname()
        vim.fn.writefile({ "x" }, file)
        vim.cmd.edit(file)
        vim.cmd.enew()
        ask()
        local buf = vim.api.nvim_get_current_buf()

        pcall(Dialog.press, keys:format(file))

        assert.equal(buf, vim.api.nvim_win_get_buf((present(Dialog.win()))))
        assert.is_true(answer("A"))
        vim.fn.delete(file)
      end)
    end

    it("keeps, giving the cursor back, when its buffer is swapped for another anyway", function()
      local before = vim.o.guicursor
      local other = vim.api.nvim_get_current_buf()
      ask()

      vim.cmd("buffer! " .. other)
      settle(function()
        return not floating()
      end)

      assert.is_false(floating())
      assert.is_false(confirmed)
      assert.equal(before, vim.api.nvim_get_option_value("guicursor", {}))
      assert.equal(opener, vim.api.nvim_get_current_win())
    end)

    it("opens after a dialog closed without its autocmds, and gives the cursor back once closed", function()
      local before = vim.o.guicursor
      ask()
      vim.cmd("noautocmd close")

      ask()
      answer("q")

      assert.equal(before, vim.api.nvim_get_option_value("guicursor", {}))
    end)

    it("stays open when a dialog cancelled in the same keys closes behind it", function()
      ask()
      vim.cmd.close()
      local second = false

      dialog.confirm({ title = "Delete the review comment", body = {}, action = "Delete" }, function()
        second = true
      end)
      settle(function()
        return false
      end)
      Dialog.press("D")
      settle(function()
        return second
      end)

      assert.is_true(second)
    end)

    it("refuses a second dialog while it is open, staying up to be answered", function()
      ask()
      local first = Dialog.win()
      local second

      dialog.choose(
        { title = "Submit the review", items = { { cells = { { "alpha" } } } }, action = "submit" },
        function(i)
          second = { i }
        end
      )
      settle(function()
        return second ~= nil
      end)

      assert.same({}, second)
      assert.equal(first, vim.api.nvim_get_current_win())
      assert.is_true(answer("A"))
    end)

    it("returns focus to where it opened, and closes, before calling back", function()
      local seen
      dialog.confirm({ title = "Abandon the review", body = {}, action = "Abandon" }, function()
        seen = { win = vim.api.nvim_get_current_win(), windows = #vim.api.nvim_list_wins() }
      end)

      Dialog.press("A")
      settle(function()
        return seen ~= nil
      end)

      assert.same({ win = opener, windows = 1 }, seen)
    end)

    it("hides the cursor while it has focus, and gives it back once closed", function()
      local before = vim.o.guicursor
      ask()
      local hidden = vim.o.guicursor

      answer("q")

      assert.truthy((hidden:find("ChangesetNoCursor", 1, true)))
      assert.equal(before, vim.api.nvim_get_option_value("guicursor", {}))
    end)

    it("scrolls back to its first line when a plugin scrolls it in the tick it opens", function()
      -- Older than the dialog's, as scrollEOF.nvim's is, so it runs first.
      local group = vim.api.nvim_create_augroup("scroll_past_end", {})
      vim.api.nvim_create_autocmd("CursorMoved", {
        group = group,
        callback = function()
          vim.fn.winrestview({ topline = 3 })
        end,
      })
      ask()

      -- Neovim's main loop fires CursorMoved between keys, and a spec runs none.
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_get_current_buf() })
      vim.api.nvim_del_augroup_by_id(group)

      assert.equal(1, vim.fn.line("w0"))
    end)

    it("scrolls back to its first line when a plugin scrolls it in a later tick", function()
      ask()
      local win = present(Dialog.win())

      -- As scrollEOF.nvim's deferred scroll, from a move made just before the dialog opened, does.
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview({ topline = 3 })
      end)
      -- Neovim fires WinScrolled before a redraw, which a spec runs none of, naming only the first window that
      -- scrolled: it can be another.
      vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(opener) })

      assert.equal(1, vim.fn.line("w0", win))
    end)

    it("turns off mini.indentscope's scope line and mini.cursorword's underline", function()
      ask()

      assert.is_true(vim.b.miniindentscope_disable)
      assert.is_true(vim.b.minicursorword_disable)
    end)

    it("centres itself on the editor", function()
      ask()

      local config = vim.api.nvim_win_get_config((present(Dialog.win())))
      assert.equal(math.floor((vim.o.columns - config.width - 2) / 2), config.col)
    end)

    it("fits a narrow editor", function()
      local columns = vim.o.columns
      vim.o.columns = 30
      ask({ title = "Abandon the review", body = { { text = ("word "):rep(40) } }, action = "Abandon" })

      local config = vim.api.nvim_win_get_config((present(Dialog.win())))
      vim.o.columns = columns
      assert.is_true(config.col >= 0 and present(config.col) + config.width + 2 <= 30)
    end)

    it("fits and centres itself again when the editor is resized", function()
      local columns = vim.o.columns
      ask({ title = "Abandon the review", body = { { text = ("word "):rep(40) } }, action = "Abandon" })

      vim.o.columns = 30
      local config = vim.api.nvim_win_get_config((present(Dialog.win())))
      vim.o.columns = columns

      assert.is_true(present(config.col) + config.width + 2 <= 30)
      assert.equal(math.floor((30 - config.width - 2) / 2), config.col)
    end)
  end)

  describe("choose", function()
    ---@type { chosen: integer?, answered: boolean }
    local result

    local ITEMS = {
      { icon = { "●", "DiagnosticOk" }, cells = { { "alpha" }, { "idle" }, { "parser" }, { "Fix the parser" } } },
      {
        icon = { "●", "DiagnosticError" },
        cells = { { "beta" }, { "blocked" } },
        unavailable = "answer its prompt first",
      },
      { icon = { "●", "DiagnosticWarn" }, cells = { { "codex" }, { "working" }, { "" }, { "" } } },
    }

    ---@param items changeset.DialogItem[]?
    ---@param focus integer|false|nil
    local function pick(items, focus)
      -- Its own table, which a dialog closed by an earlier case can't answer into.
      local mine = { answered = false }
      result = mine
      dialog.choose(
        { title = "Submit the review", items = items or ITEMS, action = "submit", focus = focus },
        function(index)
          mine.chosen, mine.answered = index, true
        end
      )
      assert.not_nil(Dialog.win(), "no dialog opened")
    end

    ---@param keys string
    ---@return integer? chosen
    local function answer(keys)
      Dialog.press(keys)
      settle(function()
        return result.answered
      end)
      return result.chosen
    end

    it("lines its rows up in columns, a row's last cell running free, and says why one can't be chosen", function()
      pick()

      assert.same({
        "▌ 1  ● alpha  idle     parser  Fix the parser",
        "  2  ● beta   blocked  answer its prompt first",
        "  3  ● codex  working",
      }, Dialog.lines())
    end)

    for _, case in ipairs({
      { keys = "<CR>", chosen = 1 },
      { keys = "j<CR>", chosen = 3 },
      { keys = "<Down><CR>", chosen = 3 },
      { keys = "jj<CR>", chosen = 3 },
      { keys = "jk<CR>", chosen = 1 },
      { keys = "j<Up><CR>", chosen = 1 },
      { keys = "k<CR>", chosen = 1 },
      { keys = "3", chosen = 3 },
    }) do
      it(("chooses row %d on %s, passing over the row that can't be chosen"):format(case.chosen, case.keys), function()
        pick()

        assert.equal(case.chosen, answer(case.keys))
        assert.equal(opener, vim.api.nvim_get_current_win())
      end)
    end

    it("starts on the first row that can be chosen", function()
      pick({ ITEMS[2], ITEMS[1] })

      assert.equal(2, answer("<CR>"))
    end)

    it("can open with no row focused, choosing nothing on <CR> until a move focuses one", function()
      pick(nil, false)

      assert.equal(3, answer("<CR>k<CR>"))
    end)

    it("keeps its focused row in view when it is taller than the editor", function()
      local lines = vim.o.lines
      vim.o.lines = 8
      pick(vim.tbl_map(function(n)
        return { cells = { { "agent " .. n } } }
      end, vim.fn.range(1, 9)))
      local win = present(Dialog.win())

      Dialog.press("jjjjj")
      vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(win) })
      local top = present(vim.fn.getwininfo(win)[1]).topline
      vim.o.lines = lines

      assert.is_true(top > 1)
    end)

    it("chooses a row clicked", function()
      pick()

      Dialog.click("codex")
      settle(function()
        return result.answered
      end)

      assert.equal(3, result.chosen)
    end)

    it("stays open on a row that can't be chosen, by its number or a click", function()
      pick()

      answer("2")
      Dialog.click("beta")
      settle(function()
        return result.answered
      end)

      assert.is_false(result.answered)
      assert.truthy(Dialog.win())
    end)

    for _, keys in ipairs({ "q", "<Esc>" }) do
      it(("calls back with nothing on %s"):format(keys), function()
        pick()

        assert.is_nil(answer(keys))
        assert.is_true(result.answered)
      end)
    end
  end)

  describe("_body", function()
    ---@param lines changeset.DialogLine[]
    ---@return string[]
    local function texts(lines)
      return vim.tbl_map(function(chunks)
        return table.concat(vim.tbl_map(function(chunk)
          return chunk[1]
        end, chunks))
      end, lines)
    end

    it("wraps each block at the measure, between words", function()
      assert.same({ "one two", "three four" }, texts(dialog._body({ { text = "one two three four" } }, 10)))
    end)

    it("breaks a word wider than the measure", function()
      assert.same({ "abcde", "fgh" }, texts(dialog._body({ { text = "abcdefgh" } }, 5)))
    end)

    it("keeps a block's own line breaks", function()
      assert.same({ "one", "two" }, texts(dialog._body({ { text = "one\ntwo" } }, 10)))
    end)

    it("keeps a quoted line's indentation and its runs of spaces", function()
      assert.same(
        { "▎ try:", "▎     if x  then", "▎       y()" },
        texts(dialog._body({ { text = "try:\n    if x  then\n      y()", quote = "Q" } }, 20))
      )
    end)

    it("drops the spaces where a line breaks", function()
      assert.same({ "one", "two" }, texts(dialog._body({ { text = "one    two" } }, 5)))
    end)

    it("bars every line of a quote", function()
      assert.same({ "▎ one two", "▎ three" }, texts(dialog._body({ { text = "one two three", quote = "Q" } }, 9)))
    end)

    it("keeps a path to one line, cutting its head", function()
      assert.same({ "…/git.lua:12" }, texts(dialog._body({ { text = "lua/changeset/git.lua:12", path = true } }, 12)))
    end)

    it("cuts a block past its lines, ending the last in an ellipsis", function()
      assert.same(
        { "▎ one two", "▎ three…" },
        texts(dialog._body({ { text = "one two three four five", quote = "Q", max_lines = 2 } }, 9))
      )
    end)
  end)

  describe("wrap", function()
    it("puts a character wider than the measure on a line of its own", function()
      assert.same({ "界", "界" }, dialog.wrap("界界", 1))
    end)
  end)

  describe("_clip", function()
    it("cuts a line whose room ends on a chunk's edge to an ellipsis in the next chunk's place", function()
      assert.same({ { "abcd", "A" }, { "…", "B" } }, dialog._clip({ { "abcd", "A" }, { "efgh", "B" } }, 5))
    end)
  end)
end)
