local changeset = require("changeset")
-- The <Plug> maps live in the plugin file, which the spec runner does not load.
vim.cmd("runtime plugin/changeset.lua")
-- What `]g` and `[g` run: the spec runner starts before startup is done, which maps the default keys.
local PREVIEW_NEXT = vim.keycode("<Plug>(changeset-preview-next)")
local PREVIEW_PREV = vim.keycode("<Plug>(changeset-preview-prev)")
local draw = require("changeset.draw")
local render = require("changeset.render")
local window = require("changeset.window")
local Fixture = require("support.git")
local Sidebar = require("support.sidebar")

---Open the sidebar from `mod.lua`, leaving the cursor in the file window.
---@return integer file The window the sidebar was opened from, where previews go.
local function open_sidebar()
  vim.cmd.edit("mod.lua")
  local file = vim.api.nvim_get_current_win()
  changeset.open()
  Sidebar.settle()
  return file
end

---@param count integer
local function step(count)
  for _ = 1, count do
    vim.cmd.normal(PREVIEW_NEXT)
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
  assert.not_equal(window.win(), win)
  assert.is_false(banded(win), "the focused window reads: " .. shown(win))
end

describe("changeset preview band", function()
  local tmp, previous_dir

  before_each(function()
    tmp, previous_dir = Fixture.enter_tempdir()
    Fixture.feature_two_files(tmp)
  end)

  after_each(function()
    changeset.close()
    vim.cmd("silent! only")
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
  end)

  describe("with ]g pressed from the file window", function()
    it("stays off another changed file it steps onto", function()
      open_sidebar()

      step(4)

      assert.equal("other.lua", vim.fn.expand("%:t"))
      assert_unbanded_here()
    end)

    it("stays off after stepping back with [g", function()
      open_sidebar()
      step(3)

      vim.cmd.normal(PREVIEW_PREV)

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
      local win = assert(window.win())
      vim.api.nvim_set_current_win(win)

      step(2)

      assert.is_true(banded(file))
    end)
  end)

  describe("with the preview made from the sidebar", function()
    ---@return integer file
    local function previewed(steps)
      local file = open_sidebar()
      local win = assert(window.win())
      vim.api.nvim_set_current_win(win)
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
      local win = assert(window.win())
      vim.api.nvim_set_current_win(win)
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

    it("stays off the notice reached with ]g from the file window", function()
      open_sidebar()

      for _ = 1, 6 do
        step(1)
        assert_unbanded_here()
      end
    end)
  end)
end)

describe("changeset preview band's band_for", function()
  ---What the band made for `row` reads on screen.
  ---@param row table
  ---@return string
  local function band_text(row)
    local winbar = render.preview_winbar(draw.band_for(row, "<CR>"))
    return vim.api.nvim_eval_statusline(winbar, { use_winbar = true, maxwidth = 70 }).str
  end

  it("offers <CR> to open on an orphan hunk, whose text is no place to land", function()
    local text = band_text({ kind = "orphan", name = "L4 return 2", path = "mod.lua", lnum = 4 })

    assert.truthy(text:find("<CR>", 1, true))
    assert.is_nil(text:find("return 2", 1, true))
  end)

  it("names the symbol <CR> lands on", function()
    local text = band_text({ kind = "symbol", name = "M.one", path = "mod.lua", lnum = 3 })

    assert.truthy(vim.endswith(text, "M.one "))
  end)
end)
