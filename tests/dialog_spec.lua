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

    it("cuts a block past its lines, ending the last in an ellipsis", function()
      assert.same(
        { "▎ one two", "▎ three…" },
        texts(dialog._body({ { text = "one two three four five", quote = "Q", max_lines = 2 } }, 9))
      )
    end)
  end)
end)
