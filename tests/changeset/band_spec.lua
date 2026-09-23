local changeset = require("plugins.changeset")
local window = require("plugins.changeset.window")
local Fixture = require("support.git")

---A repo on `trunk` with two files, then a `feature` branch that changes both.
---@param cwd string
local function init_feature_repo(cwd)
  Fixture.init_repo("trunk", cwd)
  vim.fn.writefile({ "local M = {}", "", "function M.one()", "  return 1", "end", "", "return M" }, "mod.lua")
  vim.fn.writefile({ "return { a = 1 }" }, "other.lua")
  vim.fn.writefile({ "return 0" }, "plain.lua")
  Fixture.commit("base", cwd)

  Fixture.git({ "checkout", "-q", "-b", "feature" }, cwd)
  vim.fn.writefile({ "local M = {}", "", "function M.one()", "  return 2", "end", "", "return M" }, "mod.lua")
  vim.fn.writefile({ "return { a = 1, b = 2 }" }, "other.lua")
  Fixture.commit("change", cwd)
end

---@return string
local function sidebar_text()
  return table.concat(vim.api.nvim_buf_get_lines(assert(window.buf()), 0, -1, false), "\n")
end

---Open the sidebar from `mod.lua`, leaving the cursor in the file window.
---@return integer file The window the sidebar was opened from, where previews go.
local function open_sidebar()
  vim.cmd.edit("mod.lua")
  local file = vim.api.nvim_get_current_win()
  changeset.open()
  local settled = vim.wait(10000, function()
    local text = window.buf() and sidebar_text() or ""
    return text:find("other.lua", 1, true) and not text:find("reading symbols", 1, true)
  end, 25)
  assert(settled, "the sidebar never settled")
  return file
end

---@param count integer
local function step(count)
  for _ = 1, count do
    vim.cmd.normal("]h")
  end
end

---What the window bar over `win` reads on screen.
---@param win integer
---@return string
local function shown(win)
  return vim.api.nvim_eval_statusline(vim.wo[win].winbar, { winid = win, use_winbar = true }).str
end

---@param win integer
---@return boolean
local function banded(win)
  return shown(win):find("Preview", 1, true) ~= nil
end

---The one promise under test: wherever the cursor stands, outside the sidebar,
---no band says the window is a preview.
local function assert_unbanded_here()
  local win = vim.api.nvim_get_current_win()
  assert.are_not.equal(window.win(), win)
  assert.is_false(banded(win), "the focused window reads: " .. shown(win))
end

describe("changeset preview band", function()
  local tmp, previous_dir

  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    previous_dir = vim.fn.chdir(tmp)
    init_feature_repo(tmp)
  end)

  after_each(function()
    changeset.close()
    vim.cmd("silent! only")
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
  end)

  describe("with ]h pressed from the file window", function()
    for _, steps in ipairs({ 1, 2, 3, 4 }) do
      it(("stays off after %d step(s)"):format(steps), function()
        open_sidebar()

        step(steps)

        assert_unbanded_here()
      end)
    end

    it("stays off after stepping back with [h", function()
      open_sidebar()
      step(3)

      vim.cmd.normal("[h")

      assert_unbanded_here()
    end)

    it("stays off a window split from it", function()
      open_sidebar()
      step(3)

      vim.cmd.wincmd("v")

      assert_unbanded_here()
    end)

    it("stays off once another file is edited there", function()
      open_sidebar()
      step(3)

      vim.cmd.edit("plain.lua")

      assert_unbanded_here()
    end)

    it("still bands the window once the cursor goes to the sidebar and steps", function()
      local file = open_sidebar()
      step(1)
      vim.api.nvim_set_current_win(window.win())

      step(2)

      assert.is_true(banded(file))
    end)
  end)

  describe("with the preview made from the sidebar", function()
    ---@return integer file
    local function previewed(steps)
      local file = open_sidebar()
      vim.api.nvim_set_current_win(window.win())
      step(steps)
      assert.is_true(banded(file), "the preview never landed")
      return file
    end

    it("comes off when the cursor moves into the preview", function()
      previewed(3)

      vim.cmd.wincmd("p")

      assert_unbanded_here()
    end)

    it("comes off when a mouse-style jump focuses the preview", function()
      local file = previewed(3)

      vim.api.nvim_set_current_win(file)

      assert_unbanded_here()
    end)

    it("stays off a buffer the preview showed, when it is shown again", function()
      local file = previewed(3)
      vim.api.nvim_set_current_win(file)

      vim.cmd.buffer("mod.lua")
      assert_unbanded_here()
      vim.cmd.buffer("other.lua")
      assert_unbanded_here()
    end)

    it("stays off after <C-o> back through the files the preview showed", function()
      previewed(3)
      vim.cmd.wincmd("p")

      vim.api.nvim_feedkeys(vim.keycode("<C-o>"), "nx", false)
      assert_unbanded_here()
      vim.api.nvim_feedkeys(vim.keycode("<C-i>"), "nx", false)
      assert_unbanded_here()
    end)

    it("stays off a buffer the preview showed, once the sidebar is closed", function()
      local file = previewed(3)
      changeset.close()
      vim.api.nvim_set_current_win(file)

      for _, name in ipairs({ "other.lua", "mod.lua", "other.lua" }) do
        vim.cmd.buffer(name)
        assert_unbanded_here()
      end
    end)

    it("stays off after the sidebar is closed with :q", function()
      local file = previewed(3)
      local mod = vim.fn.bufnr("mod.lua")

      vim.cmd.quit()
      -- The close runs a tick later; left pending it would shut the next spec's sidebar.
      vim.wait(1000, function()
        return vim.api.nvim_win_get_buf(file) == mod
      end, 10)

      assert_unbanded_here()
      vim.cmd.buffer("other.lua")
      assert_unbanded_here()
    end)

    it("stays off after the sidebar is toggled shut", function()
      previewed(3)

      changeset.toggle()

      assert_unbanded_here()
    end)

    it("stays off a window split from the preview", function()
      previewed(3)
      vim.cmd.wincmd("p")

      vim.cmd.wincmd("s")

      assert_unbanded_here()
    end)

    it("stays off a window split from the preview without entering it", function()
      local file = previewed(3)
      local split = vim.api.nvim_open_win(0, false, { split = "below", win = file })

      vim.api.nvim_set_current_win(split)

      assert_unbanded_here()
    end)
  end)

  describe("on a file the branch deleted", function()
    before_each(function()
      Fixture.git({ "rm", "-q", "other.lua" }, tmp)
      Fixture.commit("drop other", tmp)
    end)

    it("comes off the notice when the cursor moves into it", function()
      local file = open_sidebar()
      vim.api.nvim_set_current_win(window.win())
      local lnum
      for i, line in ipairs(vim.api.nvim_buf_get_lines(assert(window.buf()), 0, -1, false)) do
        if line:find("other.lua", 1, true) then
          lnum = i
        end
      end
      vim.api.nvim_win_set_cursor(0, { assert(lnum), 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = window.buf() })
      assert.is_true(banded(file), "the notice never landed")

      vim.cmd.wincmd("p")

      assert_unbanded_here()
    end)

    it("stays off the notice reached with ]h from the file window", function()
      open_sidebar()

      for _ = 1, 6 do
        step(1)
        assert_unbanded_here()
      end
    end)
  end)
end)
