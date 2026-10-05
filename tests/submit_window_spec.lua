local submit_window = require("changeset.submit_window")

local ALL_EVENTS = { "COMMENT", "APPROVE", "REQUEST_CHANGES" }

---@return integer[]
local function floats()
  return vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_config(win).relative ~= ""
  end, vim.api.nvim_list_wins())
end

---The buffer's own `mode` mapping for `lhs`, if any.
local function buffer_map(buf, mode, lhs)
  return vim.iter(vim.api.nvim_buf_get_keymap(buf, mode)):find(function(keymap)
    return vim.keycode(keymap.lhs) == vim.keycode(lhs)
  end)
end

local function press(buf, lhs, mode)
  local mapping = assert(buffer_map(buf, mode or "n", lhs), lhs .. " is not mapped")
  mapping.callback()
end

describe("submit_window", function()
  local source, submits, settle

  ---@param overrides table?
  ---@return integer win
  ---@return integer buf
  local function open(overrides)
    local win = submit_window.open(vim.tbl_extend("force", {
      number = 412,
      events = ALL_EVENTS,
      comments = { { id = "c", path = "a.lua", line = 4, outdated = false, body = "note" } },
      drafts = {},
      keys = { "<C-s>" },
      submit = function(submission, settled)
        submits[#submits + 1] = submission
        settle = settled
      end,
    }, overrides or {}))
    return win, vim.api.nvim_win_get_buf(win)
  end

  ---Open the body window, write `lines` and close it with `lhs`.
  local function write_body(buf, lines, lhs)
    press(buf, "b")
    local body_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(body_buf, 0, -1, false, lines)
    press(body_buf, lhs)
    vim.cmd.stopinsert()
  end

  before_each(function()
    submits, settle = {}, nil
    vim.cmd.enew()
    vim.bo.buftype = "nofile"
    source = vim.api.nvim_get_current_win()
  end)

  after_each(function()
    for _, win in ipairs(floats()) do
      pcall(vim.api.nvim_win_close, win, true)
    end
    vim.cmd.stopinsert()
  end)

  it("offers no choice for one event and submits it", function()
    local _, buf = open({ events = { "COMMENT" } })
    for _, lhs in ipairs({ "c", "a", "r" }) do
      assert.is_nil(buffer_map(buf, "n", lhs))
    end
    press(buf, "<CR>")
    assert.same({ { event = "COMMENT" } }, submits)
  end)

  it("preselects Comment of three events", function()
    local _, buf = open()
    press(buf, "<CR>")
    assert.same({ { event = "COMMENT" } }, submits)
  end)

  for lhs, event in pairs({ a = "APPROVE", r = "REQUEST_CHANGES", c = "COMMENT" }) do
    it(("submits %s once %s chooses it"):format(event, lhs), function()
      local _, buf = open()
      press(buf, "a")
      press(buf, lhs)
      press(buf, "<CR>")
      assert.same({ { event = event } }, submits)
    end)
  end

  for _, lhs in ipairs({ "<C-s>", "q" }) do
    it(("submits the body written in its window and closed with %s"):format(lhs), function()
      local win, buf = open()
      write_body(buf, { "looks", "good" }, lhs)
      assert.equal(win, vim.api.nvim_get_current_win())
      press(buf, "<CR>")
      assert.same({ { event = "COMMENT", body = "looks\ngood" } }, submits)
    end)
  end

  it("opens the body window over the preview", function()
    local win, buf = open()
    press(buf, "b")
    assert.equal(win, vim.api.nvim_win_get_config(0).win)
  end)

  for _, lhs in ipairs({ "q", "<C-s>" }) do
    it(("submits a whitespace-only body closed with %s as none"):format(lhs), function()
      local _, buf = open()
      write_body(buf, { "  ", "" }, lhs)
      press(buf, "<CR>")
      assert.same({ { event = "COMMENT" } }, submits)
    end)
  end

  it("shows the body once written", function()
    local _, buf = open()
    write_body(buf, { "looks good" }, "q")
    assert.truthy(vim.tbl_contains(vim.api.nvim_buf_get_lines(buf, 0, -1, false), " looks good"))
  end)

  for _, lhs in ipairs({ "q", "<Esc>" }) do
    it(("closes on %s without submitting, back in the window it opened from"):format(lhs), function()
      local win, buf = open()
      press(buf, lhs)
      assert.is_false(vim.api.nvim_win_is_valid(win))
      assert.same({}, submits)
      assert.equal(source, vim.api.nvim_get_current_win())
    end)
  end

  it("returns to the window it opened from after a body was written", function()
    local _, buf = open()
    write_body(buf, { "text" }, "<C-s>")
    press(buf, "q")
    assert.equal(source, vim.api.nvim_get_current_win())
  end)

  it("closes the body window with it, and neither submits nor redraws", function()
    local win, buf = open()
    press(buf, "b")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "text" })
    assert.no_errors(function()
      vim.api.nvim_win_close(win, true)
    end)
    assert.same({}, floats())
    assert.same({}, submits)
    assert.equal(source, vim.api.nvim_get_current_win())
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
  end)

  it("stays open with its event and body when the submit is refused", function()
    local win, buf = open()
    press(buf, "r")
    write_body(buf, { "why" }, "q")
    press(buf, "<CR>")
    settle("refused")
    assert.is_true(vim.api.nvim_win_is_valid(win))
    press(buf, "<CR>")
    assert.same({ event = "REQUEST_CHANGES", body = "why" }, submits[2])
  end)

  it("closes once the submit is taken", function()
    local win, buf = open()
    press(buf, "<CR>")
    settle()
    assert.is_false(vim.api.nvim_win_is_valid(win))
    assert.equal(source, vim.api.nvim_get_current_win())
  end)

  it("submits once while a submit is in flight", function()
    local _, buf = open()
    press(buf, "<CR>")
    press(buf, "<CR>")
    assert.equal(1, #submits)
  end)

  it("keeps its last row in view when a body is wider than the window", function()
    local win, buf = open({
      comments = { { id = "c", path = "a.lua", line = 4, outdated = false, body = ("x"):rep(300) } },
      drafts = { { id = "d", path = "b.lua", line = 1, body = "later" } },
    })
    local last = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_win_call(win, function()
      assert.are.equal(last, vim.fn.line("w$"))
    end)
  end)

  it("focuses the open body window on b rather than opening another", function()
    local _, buf = open()
    press(buf, "b")
    vim.cmd.wincmd("p")
    press(buf, "b")
    press(buf, "q")
    assert.same({}, floats())
  end)

  it("submits the text of a body window still open", function()
    local win, buf = open()
    press(buf, "b")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "my body" })
    vim.api.nvim_set_current_win(win)
    press(buf, "<CR>")
    assert.same({ { event = "COMMENT", body = "my body" } }, submits)
  end)

  it("opens no body window while a submit is in flight", function()
    local win, buf = open()
    press(buf, "<CR>")
    press(buf, "b")
    assert.equal(win, vim.api.nvim_get_current_win())
  end)

  it("keeps one preview when opened twice", function()
    open()
    open()
    assert.equal(1, #floats())
  end)

  it("leaves focus where the user moved it when a submit is taken", function()
    local _, buf = open()
    press(buf, "<CR>")
    vim.cmd.split()
    local other = vim.api.nvim_get_current_win()
    settle()
    assert.equal(other, vim.api.nvim_get_current_win())
    vim.api.nvim_win_close(other, true)
  end)

  it("widens to a body wider than it opened", function()
    local win, buf = open()
    local before = vim.api.nvim_win_get_width(win)
    write_body(buf, { ("x"):rep(before + 10) }, "q")
    assert.is_true(vim.api.nvim_win_get_width(win) > before)
  end)

  it("describes every key", function()
    local _, buf = open()
    for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      assert.truthy(keymap.desc, keymap.lhs)
    end
  end)

  it("names the PR in its title and what a submit sends in its footer", function()
    local win, buf = open()
    local config = vim.api.nvim_win_get_config(win)
    assert.equal(" Submit review · #412 ", config.title[1][1])
    assert.equal(" comment on #412 ", config.footer[1][1])
    press(buf, "a")
    assert.equal(" approve #412 ", vim.api.nvim_win_get_config(win).footer[1][1])
    press(buf, "r")
    assert.equal(" request changes on #412 ", vim.api.nvim_win_get_config(win).footer[1][1])
  end)
end)
