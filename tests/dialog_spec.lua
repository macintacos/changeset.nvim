local Dialog = require("support.dialog")
local dialog = require("changeset.dialog")

---Waits for a scheduled answer, or a moment for one that never comes.
---@param answered fun(): boolean
local function settle(answered)
  vim.wait(200, answered, 10)
end

describe("changeset.dialog", function()
  local opener

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
      assert(Dialog.win(), "no dialog opened")
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
      assert.truthy(lines[#lines - 1]:find("Keep%s+Abandon$"))
      assert.equal("Abandon the review", Dialog.title())
    end)

    for _, case in ipairs({
      { keys = "a", confirms = true },
      { keys = "k", confirms = false },
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

        assert.equal(buf, vim.api.nvim_win_get_buf((assert(Dialog.win()))))
        assert.is_true(answer("a"))
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
      assert.equal(before, vim.o.guicursor)
      assert.equal(opener, vim.api.nvim_get_current_win())
    end)

    it("returns focus to where it opened, and closes, before calling back", function()
      local seen
      dialog.confirm({ title = "Abandon the review", body = {}, action = "Abandon" }, function()
        seen = { win = vim.api.nvim_get_current_win(), windows = #vim.api.nvim_list_wins() }
      end)

      Dialog.press("a")
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

      assert.truthy(hidden:find("ChangesetNoCursor", 1, true))
      assert.equal(before, vim.o.guicursor)
    end)

    it("centres itself on the editor", function()
      ask()

      local config = vim.api.nvim_win_get_config((assert(Dialog.win())))
      assert.equal(math.floor((vim.o.columns - config.width - 2) / 2), config.col)
    end)

    it("fits a narrow editor", function()
      local columns = vim.o.columns
      vim.o.columns = 30
      ask({ title = "Abandon the review", body = { { text = ("word "):rep(40) } }, action = "Abandon" })

      local config = vim.api.nvim_win_get_config((assert(Dialog.win())))
      vim.o.columns = columns
      assert.is_true(config.col >= 0 and config.col + config.width + 2 <= 30)
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
    local function pick(items)
      -- Its own table, which a dialog closed by an earlier case can't answer into.
      local mine = { answered = false }
      result = mine
      dialog.choose({ title = "Send the review", items = items or ITEMS, action = "send" }, function(index)
        mine.chosen, mine.answered = index, true
      end)
      assert(Dialog.win(), "no dialog opened")
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
    ---@param lines [string, string?][][]
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
end)
