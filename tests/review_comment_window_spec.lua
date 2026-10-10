local review_comment_window = require("changeset.review_comment_window")
local present = require("support.present")

local SAVE_KEYS = { "<C-CR>", "<C-s>" }

---@return integer?
local function float()
  return vim.iter(vim.api.nvim_list_wins()):find(function(win)
    return vim.api.nvim_win_get_config(win).relative ~= ""
  end)
end

---The buffer's own `mode` mapping for `lhs`, if any.
local function buffer_map(buf, mode, lhs)
  return vim.iter(vim.api.nvim_buf_get_keymap(buf, mode)):find(function(keymap)
    return vim.keycode(keymap.lhs) == vim.keycode(lhs)
  end)
end

local function press(buf, mode, lhs)
  local mapping = present(buffer_map(buf, mode, lhs), lhs .. " is not mapped in " .. mode)
  if mapping.callback then
    return mapping.callback()
  end
  vim.api.nvim_feedkeys((mode == "i" and "a" or "") .. vim.keycode(lhs), "x", false)
end

describe("review_comment_window", function()
  local source ---@type integer
  local saves ---@type string[]
  ---@type fun(err: string?)?
  local answer
  local kept ---@type string[]

  ---@param overrides table?
  ---@return integer win
  ---@return integer buf
  local function open(overrides)
    local win = review_comment_window.open(vim.tbl_extend("force", {
      line = 5,
      title = "line 5",
      save_desc = "Save",
      close_desc = "Close",
      keys = SAVE_KEYS,
      save = function(body, done)
        saves[#saves + 1] = body
        answer = done
      end,
      keep = function(body)
        kept[#kept + 1] = body
      end,
      comment = { path = "a.lua", line = 5, body = "" },
    }, overrides or {}) --[[@as changeset.ReviewCommentWindowOpts]])
    return win, vim.api.nvim_win_get_buf(win)
  end

  before_each(function()
    saves, answer, kept = {}, nil, {}
    vim.cmd.enew()
    vim.bo.buftype = "nofile"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(("x\n"):rep(9) .. "x", "\n"))
    source = vim.api.nvim_get_current_win()
  end)

  after_each(function()
    local win = float()
    if win then
      vim.api.nvim_win_close(win, true)
    end
    vim.cmd.stopinsert()
  end)

  for _, line in ipairs({ 1, 5, 10 }) do
    it(("opens a focused float under line %d"):format(line), function()
      local win = open({ line = line })
      local config = vim.api.nvim_win_get_config(win)

      assert.equal(win, float())
      assert.equal(win, vim.api.nvim_get_current_win())
      assert.equal("win", config.relative)
      assert.equal(source, config.win)
      assert.same({ line - 1, 0 }, config.bufpos)
    end)
  end

  it("pads its text a cell in from its left border, wrapped rows too", function()
    local win, buf = open()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { ("a"):rep(200) })
    vim.cmd.redraw()

    local first = vim.fn.screenpos(win, 1, 1)
    local wrapped = vim.iter(vim.fn.range(1, 200)):find(function(col)
      return vim.fn.screenpos(win, 1, col).row > first.row
    end)
    local border = vim.fn.win_screenpos(win)[2]
    assert.equal(border + 2, first.col)
    assert.equal(border + 2, vim.fn.screenpos(win, 1, wrapped).col)
  end)

  for name, case in pairs({
    line = { comment = { path = "lua/a.lua", line = 5 }, want = "review-comment://lua/a.lua:5" },
    lines = { comment = { path = "lua/a.lua", start_line = 4, line = 5 }, want = "review-comment://lua/a.lua:4-5" },
    ["whole file"] = { comment = { path = "lua/a.lua" }, want = "review-comment://lua/a.lua" },
  }) do
    it(("names its buffer for its comment's file and %s, a name no write puts on disk"):format(name), function()
      case.comment.body = ""
      local _, buf = open({ comment = case.comment })

      local written, err = pcall(function()
        vim.cmd("write!")
      end)
      assert.equal(case.want, vim.api.nvim_buf_get_name(buf))
      assert.is_false(written)
      -- E382: refused for its 'buftype', whatever the name.
      assert.truthy((tostring(err):find("E382", 1, true)))
    end)
  end

  it("opens again on its comment before the window it replaces has closed", function()
    local first = open()
    vim.cmd.stopinsert()
    vim.cmd.wincmd("p")
    assert.is_true(vim.api.nvim_win_is_valid(first))

    local win = open()

    assert.equal(win, vim.api.nvim_get_current_win())
  end)

  it("holds editable markdown and labels itself", function()
    local win, buf = open({ title = "lines 4-5" })
    local config = vim.api.nvim_win_get_config(win)

    assert.equal("markdown", vim.bo[buf].filetype)
    assert.is_true(vim.bo[buf].modifiable)
    local title = present(config.title)
    assert.equal(" lines 4-5 ", present(title[1])[1])
  end)

  it("leads its title with its icon, over the title's background", function()
    local float_title = vim.api.nvim_get_hl(0, { name = "FloatTitle" })
    vim.api.nvim_set_hl(0, "ReviewCommentWindowSpecIcon", { fg = 0x112233 })
    vim.api.nvim_set_hl(0, "FloatTitle", { fg = 0xeeeeee, bg = 0x445566 })

    local win = open({ title = "whole file", icon = { "X", "ReviewCommentWindowSpecIcon" } })

    local title = present(vim.api.nvim_win_get_config(win).title)
    local icon = vim.api.nvim_get_hl(0, { name = present(present(title[1])[2]), link = false })
    vim.api.nvim_set_hl(0, "FloatTitle", float_title --[[@as vim.api.keyset.highlight]])
    assert.equal(" X", present(title[1])[1])
    assert.equal(" whole file ", present(title[2])[1])
    assert.same({ 0x112233, 0x445566 }, { icon.fg, icon.bg })
  end)

  ---The footer's chunks, present only while the footer is drawn.
  local function footer_chunks(win)
    return present(vim.api.nvim_win_get_config(win).footer)
  end

  ---The footer's text, its chunks joined.
  local function footer(win)
    return table.concat(vim.tbl_map(function(chunk)
      return chunk[1]
    end, footer_chunks(win)))
  end

  ---The keys the footer draws as keycaps, in order.
  local function keycaps(win)
    return vim
      .iter(footer_chunks(win))
      :filter(function(chunk)
        return chunk[2] == require("changeset.highlights").KEYCAP_HL
      end)
      :map(function(chunk)
        return vim.trim(chunk[1])
      end)
      :totable()
  end

  it("names its first save key, alone, then q, as keycaps at the right of the footer", function()
    local win = open({ keys = { "<C-CR>", "<C-s>" } })
    assert.same({ "<C-CR>", "q" }, keycaps(win))
    assert.truthy(footer(win):find("save.+draft"), footer(win))
    assert.equal("right", vim.api.nvim_win_get_config(win).footer_pos)
  end)

  it("writes the save key in Neovim's own notation", function()
    local win = open({ keys = { "<c-enter>" } })
    assert.same({ "<C-CR>", "q" }, keycaps(win))
  end)

  it("drops the save key from a footer too narrow for it, rather than cut it to another key", function()
    vim.cmd("vsplit")
    vim.cmd("vertical resize 24")
    local win = open()
    local config = vim.api.nvim_win_get_config(win)
    vim.api.nvim_win_close(win, true)
    vim.cmd.close()
    assert.is_nil(config.footer)
  end)

  it("describes its keys with the descriptions it is given", function()
    local _, buf = open({ save_desc = "Save it", close_desc = "Close it" })
    for _, mode in ipairs({ "i", "n" }) do
      for _, lhs in ipairs(SAVE_KEYS) do
        assert.equal("Save it", buffer_map(buf, mode, lhs).desc)
      end
      assert.equal("Close it", buffer_map(buf, mode, "<S-Esc>").desc)
    end
    assert.equal("Close it", buffer_map(buf, "n", "q").desc)
    assert.equal("Close it", buffer_map(buf, "n", "<Esc>").desc)
  end)

  it("saves on each save key, in insert and normal mode", function()
    local _, buf = open()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "text" })
    for _, mode in ipairs({ "i", "n" }) do
      for _, lhs in ipairs(SAVE_KEYS) do
        local before = #saves
        press(buf, mode, lhs)
        assert.equal(before + 1, #saves)
        present(answer)("refused")
      end
    end
  end)

  it("binds the keys it is given in place of the defaults", function()
    local _, buf = open({ keys = { "<C-j>" } })
    for _, mode in ipairs({ "i", "n" }) do
      assert.truthy(buffer_map(buf, mode, "<C-j>"))
      assert.is_nil(buffer_map(buf, mode, "<C-s>"))
    end
  end)

  it("saves the buffer's lines joined by newlines", function()
    local _, buf = open()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "", "two" })
    press(buf, "i", "<C-s>")
    assert.same({ "one\n\ntwo" }, saves)
  end)

  it("closes, wiping its buffer, once the save succeeds", function()
    local win, buf = open()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "text" })
    press(buf, "i", "<C-s>")
    present(answer)(nil)

    assert.is_false(vim.api.nvim_win_is_valid(win))
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
  end)

  for mode, enter in pairs({ insert = "a", replace = "R" }) do
    it(
      ("saved from %s mode, returns to the user's file in normal mode with its cursor in place"):format(mode),
      function()
        vim.api.nvim_buf_set_lines(0, 1, 2, false, { "local value = 1" })
        vim.api.nvim_win_set_cursor(source, { 2, 8 })
        local leaves = {}
        local group = vim.api.nvim_create_augroup("review_comment_window_spec", {})
        vim.api.nvim_create_autocmd("InsertLeave", {
          group = group,
          callback = function(args)
            leaves[#leaves + 1] = args.buf
          end,
        })
        local source_buf = vim.api.nvim_get_current_buf()

        local win, buf = open({
          save = function(_, done)
            vim.defer_fn(function()
              done(nil)
            end, 50)
          end,
        })
        -- A close that leaves the mode behind would hold "!" forever; end it so the case fails.
        vim.defer_fn(vim.cmd.stopinsert, 500)
        -- startinsert waits for typeahead, so the keys enter the mode themselves; "!" then holds it
        -- until something leaves it, here the answered save.
        vim.api.nvim_feedkeys(enter .. "hello" .. vim.keycode("<C-s>"), "x!", false)
        vim.wait(100, function()
          return not vim.api.nvim_win_is_valid(win)
        end)
        vim.api.nvim_del_augroup_by_id(group)

        assert.equal(source, vim.api.nvim_get_current_win())
        assert.equal("n", vim.api.nvim_get_mode().mode)
        assert.same({ 2, 8 }, vim.api.nvim_win_get_cursor(source))
        assert.same({ buf }, leaves)
        assert.is_false(vim.tbl_contains(leaves, source_buf))
      end
    )
  end

  it("fits right of the source window's gutter", function()
    vim.cmd("vsplit")
    vim.cmd("vertical resize 40")
    vim.wo.number = true
    vim.wo.signcolumn = "yes"
    source = vim.api.nvim_get_current_win()

    local win = open()
    local left = vim.fn.screenpos(win, 1, 1).col
    local width = vim.api.nvim_win_get_width(win)
    local right_edge = vim.fn.win_screenpos(source)[2] + vim.fn.winwidth(source)
    vim.api.nvim_win_close(win, true)
    vim.cmd.close()

    -- +1 for the right border.
    assert.is_true(left + width + 1 <= right_edge)
  end)

  it("takes the user's markdown window settings", function()
    local group = vim.api.nvim_create_augroup("review_comment_window_spec", {})
    vim.api.nvim_create_autocmd("FileType", { group = group, pattern = "markdown", command = "setlocal spell" })
    local win = open()
    vim.api.nvim_del_augroup_by_id(group)
    assert.is_true(vim.wo[win].spell)
  end)

  it("stays open with its text when the save is refused", function()
    local win, buf = open()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "keep me" })
    press(buf, "i", "<C-s>")
    present(answer)("boom")

    assert.is_true(vim.api.nvim_win_is_valid(win))
    assert.same({ "keep me" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("saves once while a save is in flight, and again after a refusal", function()
    local _, buf = open()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "text" })
    press(buf, "i", "<C-s>")
    press(buf, "n", "<C-CR>")
    assert.equal(1, #saves)

    present(answer)("boom")
    press(buf, "i", "<C-s>")
    assert.equal(2, #saves)
  end)

  it("closes on q without saving", function()
    local win, buf = open()
    press(buf, "n", "q")
    assert.is_false(vim.api.nvim_win_is_valid(win))
    assert.equal(0, #saves)
  end)

  it("takes a save answered after q closed it", function()
    local _, buf = open()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "text" })
    press(buf, "i", "<C-s>")
    press(buf, "n", "q")
    assert.no_errors(function()
      present(answer)(nil)
    end)
  end)

  it("keeps the text when q closes it", function()
    local win, buf = open()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two" })
    press(buf, "n", "q")
    assert.is_false(vim.api.nvim_win_is_valid(win))
    assert.same({ "one\ntwo" }, kept)
  end)

  it("keeps the text when :q closes it", function()
    local _, buf = open()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "text" })
    vim.cmd.quit()
    assert.same({ "text" }, kept)
  end)

  it("closes, keeping the text, when :edit! reloads its buffer", function()
    local win, buf = open()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "text" })
    vim.cmd.stopinsert()
    vim.cmd("edit!")
    vim.wait(100, function()
      return not vim.api.nvim_win_is_valid(win)
    end)
    assert.is_false(vim.api.nvim_win_is_valid(win))
    assert.same({ "text" }, kept)
    local ns = vim.api.nvim_get_namespaces()["changeset.review_comment_window"]
    assert.same({}, vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(source), ns, 0, -1, {}))
  end)

  it("closes, keeping the text, once its source window closes", function()
    local win, buf = open()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "text" })
    vim.cmd.stopinsert()
    vim.cmd.split()
    local other = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_close(source, true)
    source = other
    -- Headless Neovim fires no WinScrolled for the windows the close resized.
    vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(other) })
    vim.wait(100, function()
      return not vim.api.nvim_win_is_valid(win)
    end)
    assert.is_false(vim.api.nvim_win_is_valid(win))
    assert.same({ "text" }, kept)
  end)

  it("closes, keeping the text, as soon as focus leaves it", function()
    local win, buf = open()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "text" })
    vim.api.nvim_set_current_win(source)
    vim.wait(100, function()
      return not vim.api.nvim_win_is_valid(win)
    end)
    assert.is_false(vim.api.nvim_win_is_valid(win))
    assert.same({ "text" }, kept)
  end)

  it("stays open while focus is in a window it holds for, closing once focus leaves it again", function()
    local win = open()
    present(review_comment_window.current()).hold(function() end)
    vim.api.nvim_set_current_win(source)
    vim.wait(50)
    assert.is_true(vim.api.nvim_win_is_valid(win))
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_set_current_win(source)
    vim.wait(100, function()
      return not vim.api.nvim_win_is_valid(win)
    end)
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)

  it("reports, while current, its source window, its comment and its text", function()
    local comment = { path = "a.lua", line = 5, body = "" }
    local _, buf = open({ comment = comment })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two" })
    local current = present(review_comment_window.current())
    assert.equal(source, current.source)
    assert.equal(comment, current.comment)
    assert.equal("one\ntwo", current.text())
    vim.api.nvim_set_current_win(source)
    assert.is_nil(review_comment_window.current())
  end)

  it("runs what follows its close once it has closed, insert mode ended", function()
    local win = open()
    vim.api.nvim_feedkeys("a", "x", false)
    local after
    present(review_comment_window.current()).close(function()
      after = { valid = vim.api.nvim_win_is_valid(win), mode = vim.api.nvim_get_mode().mode }
    end)
    vim.wait(500, function()
      return after ~= nil
    end)
    assert.same({ valid = false, mode = "n" }, after)
    assert.same({ "" }, kept)
  end)

  it("keeps nothing when discarded", function()
    local win, buf = open()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "text" })
    present(review_comment_window.current()).discard()
    vim.wait(100, function()
      return not vim.api.nvim_win_is_valid(win)
    end)
    assert.is_false(vim.api.nvim_win_is_valid(win))
    assert.same({}, kept)
  end)

  it("keeps the text when closed from outside", function()
    local win, buf = open()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "text" })
    vim.api.nvim_win_close(win, true)
    assert.same({ "text" }, kept)
  end)

  for _, mode in ipairs({ "i", "n" }) do
    it(("closes on <S-Esc> in %s mode, keeping the text"):format(mode), function()
      local win, buf = open()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "text" })
      press(buf, mode, "<S-Esc>")
      vim.wait(100, function()
        return not vim.api.nvim_win_is_valid(win)
      end)
      assert.is_false(vim.api.nvim_win_is_valid(win))
      assert.same({ "text" }, kept)
    end)
  end

  it("keeps empty text too, leaving emptiness to the caller", function()
    local _, buf = open()
    press(buf, "n", "q")
    assert.same({ "" }, kept)
  end)

  it("closes on a save of only whitespace, handing the text to keep instead", function()
    local win, buf = open()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "  ", "" })
    press(buf, "i", "<C-s>")
    vim.wait(100, function()
      return not vim.api.nvim_win_is_valid(win)
    end)

    assert.same({}, saves)
    assert.is_false(vim.api.nvim_win_is_valid(win))
    assert.same({ "  \n" }, kept)
  end)

  it("keeps nothing once a save is taken", function()
    local _, buf = open()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "text" })
    press(buf, "i", "<C-s>")
    present(answer)(nil)
    assert.same({}, kept)
  end)

  it("keeps nothing while a refused save leaves it open", function()
    local _, buf = open()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "text" })
    press(buf, "i", "<C-s>")
    present(answer)("boom")
    assert.same({}, kept)
  end)

  it("keeps the text when q closes it during a save", function()
    local _, buf = open()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "text" })
    press(buf, "i", "<C-s>")
    press(buf, "n", "q")
    assert.same({ "text" }, kept)
    assert.no_errors(function()
      present(answer)(nil)
    end)
  end)

  it("opens with a body, the cursor at its end", function()
    local win, buf = open({ body = "one\ntwo" })
    assert.same({ "one", "two" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.equal(2, vim.api.nvim_win_get_cursor(win)[1])
  end)

  it("lists <S-Esc> under ?", function()
    local _, buf = open()
    assert.truthy(buffer_map(buf, "n", "<S-Esc>").desc)
  end)

  describe("?", function()
    local group ---@type integer

    before_each(function()
      group = vim.api.nvim_create_augroup("review_comment_window_spec_markdown", {})
      -- As mkdnflow maps a markdown buffer's keys: on the current buffer, as its FileType fires.
      vim.api.nvim_create_autocmd("FileType", {
        group = group,
        pattern = "markdown",
        callback = function()
          vim.api.nvim_buf_set_keymap(0, "n", ",ac", "<Nop>", { desc = "Align the table column" })
        end,
      })
    end)

    after_each(function()
      vim.api.nvim_del_augroup_by_id(group)
      package.loaded["which-key"] = nil
    end)

    it("hands which-key its own keys, not a markdown plugin's, and gives the buffer those back after", function()
      local listed ---@type string[]
      -- which-key lists the current buffer's maps once its popup is up, whatever buffer it is handed.
      package.loaded["which-key"] = {
        show = function()
          listed = vim.tbl_map(function(keymap)
            return keymap.lhs
          end, vim.api.nvim_buf_get_keymap(0, "n"))
        end,
      }
      local _, buf = open()

      press(buf, "n", "?")

      assert.is_true(vim.tbl_contains(listed, "q"))
      assert.is_false(vim.tbl_contains(listed, ",ac"))
      assert.truthy(buffer_map(buf, "n", ",ac"))
    end)

    it("lists its own keys, not a markdown plugin's, in a float of its own without which-key", function()
      local win, buf = open()

      press(buf, "n", "?")

      local shown = present(vim.iter(vim.api.nvim_list_wins()):find(function(each)
        return each ~= win and vim.api.nvim_win_get_config(each).relative ~= ""
      end))
      local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(shown), 0, -1, false), "\n")
      vim.api.nvim_win_close(shown, true)
      assert.truthy((text:find("Show these keymaps", 1, true)))
      assert.is_nil((text:find(",ac", 1, true)))
    end)
  end)

  describe("inline", function()
    before_each(function()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(("x\n"):rep(39) .. "x", "\n"))
      vim.cmd.redraw()
    end)

    ---The screen rows of the float's top and bottom border, once drawn.
    local function borders(win)
      vim.cmd.redraw()
      local top = vim.api.nvim_win_get_position(win)[1] + 1
      return top, top + vim.api.nvim_win_get_height(win) + 1
    end

    local function row_of(line)
      return vim.fn.screenpos(source, line, 1).row
    end

    ---The source buffer's extmarks that draw virtual lines.
    local function padding()
      return vim.tbl_filter(function(mark)
        return present(mark[4]).virt_lines ~= nil
      end, vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(source), -1, 0, -1, { details = true }))
    end

    ---Tell the window its source scrolled or resized, as Neovim does from its main loop.
    local function notify()
      vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(source) })
    end

    local function scroll_to(topline)
      vim.api.nvim_win_call(source, function()
        vim.fn.winrestview({ topline = topline, lnum = topline })
      end)
      notify()
    end

    it("covers no line, a blank row between it and the lines above and below, a blank column left of it", function()
      local win = open({ line = 5 })
      local top, bottom = borders(win)
      assert.equal(row_of(5), top - 2)
      assert.equal(row_of(6), bottom + 2)
      assert.equal(vim.fn.screenpos(source, 5, 1).col, vim.api.nvim_win_get_position(win)[2])
    end)

    it("sits under the last screen row of a wrapped line", function()
      vim.api.nvim_buf_set_lines(0, 4, 5, false, { ("w"):rep(200) })
      local win = open({ line = 5 })
      local top, bottom = borders(win)
      assert.equal(vim.fn.screenpos(source, 5, 200).row, top - 2)
      assert.equal(row_of(6), bottom + 2)
    end)

    it("shows under a line running past the edge of a window that doesn't wrap", function()
      vim.wo[source].wrap = false
      vim.api.nvim_buf_set_lines(0, 4, 5, false, { ("w"):rep(vim.api.nvim_win_get_width(source) * 2) })
      local hide = vim.api.nvim_win_get_config((open({ line = 5 }))).hide
      vim.wo[source].wrap = true
      assert.is_false(hide)
    end)

    it("scrolls a line near the bottom up just far enough to fit the box under it", function()
      local win = open({ line = 20 })
      local top, bottom = borders(win)
      assert.equal(row_of(20), top - 2)
      assert.equal(vim.fn.win_screenpos(source)[1] + vim.api.nvim_win_get_height(source) - 1, bottom)
      assert.is_false(vim.api.nvim_win_get_config(win).hide)
    end)

    it("moves with its line as the source scrolls", function()
      local win = open({ line = 10 })
      scroll_to(4)
      local top, bottom = borders(win)
      assert.equal(7, row_of(10))
      assert.equal(row_of(10), top - 2)
      assert.equal(row_of(11), bottom + 2)
    end)

    it("closes, keeping the text, once its line is scrolled out of the source", function()
      local win, buf = open({ line = 5 })
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "text" })
      scroll_to(6)
      vim.wait(100, function()
        return not vim.api.nvim_win_is_valid(win)
      end)
      assert.is_false(vim.api.nvim_win_is_valid(win))
      assert.same({ "text" }, kept)
    end)

    it("hides while held and its line is scrolled out of the source, and comes back with it", function()
      local win = open({ line = 5 })
      present(review_comment_window.current()).hold(function() end)
      scroll_to(6)
      assert.is_true(vim.api.nvim_win_get_config(win).hide)
      scroll_to(1)
      assert.is_false(vim.api.nvim_win_get_config(win).hide)
    end)

    it("hides while only the blank row above it fits under its line", function()
      local win = open({ line = 30 })
      present(review_comment_window.current()).hold(function() end)
      local last = vim.fn.win_screenpos(source)[1] + vim.api.nvim_win_get_height(source) - 1
      scroll_to(30 - vim.api.nvim_win_get_height(source) + 2)
      assert.equal(last - 1, row_of(30))
      assert.is_true(vim.api.nvim_win_get_config(win).hide)
    end)

    it("shows while its first row fits under its line, past filler scrolled off above the top line", function()
      local win = open({ line = 30 })
      local top = 33 - vim.api.nvim_win_get_height(source)
      local filler = { virt_lines = { { { "a" } }, { { "b" } } }, virt_lines_above = true }
      local ns = vim.api.nvim_create_namespace("review_comment_window_spec")
      vim.api.nvim_buf_set_extmark(vim.api.nvim_win_get_buf(source), ns, top - 1, 0, filler)
      vim.api.nvim_win_call(source, function()
        vim.fn.winrestview({ topline = top, topfill = 0, lnum = top })
      end)
      notify()
      assert.is_false(vim.api.nvim_win_get_config(win).hide)
    end)

    it("keeps its padding under its line when the source's lines are replaced", function()
      open({ line = 5 })
      local source_buf = vim.api.nvim_win_get_buf(source)
      vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, vim.api.nvim_buf_get_lines(source_buf, 0, -1, false))
      vim.wait(100, function()
        return present(padding()[1])[2] == 4
      end)
      assert.equal(4, present(padding()[1])[2])
    end)

    it("re-fits its width to a resized source", function()
      vim.cmd("vsplit")
      vim.cmd("vertical resize 40")
      source = vim.api.nvim_get_current_win()
      local win = open()
      vim.api.nvim_win_set_width(source, 60)
      notify()
      local width = vim.api.nvim_win_get_width(win)
      vim.api.nvim_win_close(win, true)
      vim.cmd.close()
      assert.equal(57, width)
    end)

    for name, close in pairs({
      q = function(buf)
        press(buf, "n", "q")
      end,
      [":q"] = function()
        vim.cmd.quit()
      end,
      ["<C-w>c"] = function()
        vim.cmd.wincmd("c")
      end,
      ["a taken save"] = function(buf)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "text" })
        press(buf, "n", "<C-s>")
        present(answer)(nil)
      end,
    }) do
      it(("takes its padding with it when %s closes it"):format(name), function()
        local _, buf = open()
        assert.equal(1, #padding())
        close(buf)
        assert.same({}, padding())
      end)
    end
  end)
end)
