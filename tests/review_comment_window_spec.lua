local review_comment_window = require("changeset.review_comment_window")

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
  local mapping = assert(buffer_map(buf, mode, lhs), lhs .. " is not mapped in " .. mode)
  mapping.callback()
end

describe("review_comment_window", function()
  local source, saves, answer

  ---@param overrides table?
  ---@return integer win
  ---@return integer buf
  local function open(overrides)
    local win = review_comment_window.open(vim.tbl_extend("force", {
      line = 5,
      title = "line 5",
      footer = "pending review on #412",
      keys = SAVE_KEYS,
      save = function(body, done)
        saves[#saves + 1] = body
        answer = done
      end,
    }, overrides or {}))
    return win, vim.api.nvim_win_get_buf(win)
  end

  before_each(function()
    saves, answer = {}, nil
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

  it("holds editable markdown and labels itself", function()
    local win, buf = open({ title = "lines 4-5", footer = "pending review on #7" })
    local config = vim.api.nvim_win_get_config(win)

    assert.equal("markdown", vim.bo[buf].filetype)
    assert.is_true(vim.bo[buf].modifiable)
    assert.truthy(config.title[1][1]:find("lines 4-5", 1, true))
    assert.truthy(config.footer[1][1]:find("pending review on #7", 1, true))
  end)

  it("saves on each save key, in insert and normal mode", function()
    local _, buf = open()
    for _, mode in ipairs({ "i", "n" }) do
      for _, lhs in ipairs(SAVE_KEYS) do
        assert.truthy(buffer_map(buf, mode, lhs).desc)
        local before = #saves
        press(buf, mode, lhs)
        assert.equal(before + 1, #saves)
        answer("refused")
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

  it("closes, wiping its buffer and leaving insert mode, once the save succeeds", function()
    local win, buf = open()
    local stopinsert, stops = vim.cmd.stopinsert, 0
    vim.cmd.stopinsert = function()
      stops = stops + 1
    end
    press(buf, "i", "<C-s>")
    answer(nil)
    vim.cmd.stopinsert = stopinsert

    assert.is_false(vim.api.nvim_win_is_valid(win))
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
    assert.equal(1, stops)
  end)

  it("stays open with its text when the save is refused", function()
    local win, buf = open()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "keep me" })
    press(buf, "i", "<C-s>")
    answer("boom")

    assert.is_true(vim.api.nvim_win_is_valid(win))
    assert.same({ "keep me" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("saves once while a save is in flight, and again after a refusal", function()
    local _, buf = open()
    press(buf, "i", "<C-s>")
    press(buf, "n", "<C-CR>")
    assert.equal(1, #saves)

    answer("boom")
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
    press(buf, "i", "<C-s>")
    press(buf, "n", "q")
    assert.no_errors(function()
      answer(nil)
    end)
  end)
end)
