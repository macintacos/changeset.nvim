local changeset = require("plugins.changeset")
local window = require("plugins.changeset.window")
local Fixture = require("support.git")

---@param count integer
---@param changed table<integer, true>? Lines to rewrite.
---@return string[]
local function numbered(count, changed)
  local lines = {}
  for i = 1, count do
    lines[i] = (changed or {})[i] and ("changed " .. i) or ("line " .. i)
  end
  return lines
end

---A `feature` branch changing lines 2 and 8 of `mod.lua` and the last of `other.lua`,
---beside a `plain.lua` it leaves alone. No server answers in the specs, so every
---hunk is an orphan: `mod.lua` → "Other changes" → L2, L8.
---@param cwd string
local function init_feature_repo(cwd)
  Fixture.init_repo("trunk", cwd)
  vim.fn.writefile(numbered(10), "mod.lua")
  vim.fn.writefile({ "local a = 1", "", "return 1" }, "other.lua")
  vim.fn.writefile({ "return 0" }, "plain.lua")
  Fixture.commit("base", cwd)

  Fixture.git({ "checkout", "-q", "-b", "feature" }, cwd)
  vim.fn.writefile(numbered(10, { [2] = true, [8] = true }), "mod.lua")
  vim.fn.writefile({ "local a = 1", "", "return 2" }, "other.lua")
  Fixture.commit("change", cwd)
end

---@return string
local function sidebar_text()
  return table.concat(vim.api.nvim_buf_get_lines(assert(window.buf()), 0, -1, false), "\n")
end

---Wait for the tree to hold both files with every file's symbols read.
local function settle()
  local settled = vim.wait(10000, function()
    local text = window.buf() and sidebar_text() or ""
    return text:find("other.lua", 1, true) and not text:find("reading symbols", 1, true)
  end, 25)
  assert(settled, "the sidebar never settled")
end

---Let the scheduled "you are here" tracking run.
local function flush()
  local flushed = false
  vim.schedule(function()
    flushed = true
  end)
  vim.wait(1000, function()
    return flushed
  end)
end

---The text of the line the sidebar's cursor is on.
---@return string
local function sidebar_cursor_line()
  local win = assert(window.win())
  return vim.api.nvim_buf_get_lines(window.buf(), vim.api.nvim_win_get_cursor(win)[1] - 1, -1, false)[1]
end

---Put the sidebar's cursor on the first line containing `text`. Headless, setting a
---cursor fires no `CursorMoved`, so this stands in for the user moving it without a preview.
---@param text string
local function park_sidebar_cursor(text)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(window.buf(), 0, -1, false)) do
    if line:find(text, 1, true) then
      vim.api.nvim_win_set_cursor(window.win(), { i, 0 })
      return
    end
  end
  error("no sidebar line contains " .. text)
end

describe("changeset sidebar focus", function()
  local tmp, previous_dir

  -- The tree resolves its repo from the current buffer, which falls back to the
  -- process cwd, and the fixture writes relative paths, so it has to be entered.
  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    previous_dir = vim.fn.chdir(tmp)
    assert(previous_dir ~= "", "could not enter the fixture directory")
    init_feature_repo(tmp)
  end)

  after_each(function()
    changeset.close()
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
  end)

  it("lands on the row you are on when <leader>gp focuses the sidebar", function()
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    changeset.open()
    settle()

    changeset.toggle()

    assert.equal(window.win(), vim.api.nvim_get_current_win())
    assert.truthy(sidebar_cursor_line():find("Other changes", 1, true))
  end)

  it("lands on the row you are on when focus arrives by a route other than <leader>gp", function()
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    changeset.open()
    settle()
    park_sidebar_cursor("other.lua")

    vim.api.nvim_set_current_win(window.win())

    assert.truthy(sidebar_cursor_line():find("Other changes", 1, true))
  end)

  it("leaves the sidebar cursor where it was when you are outside the changeset", function()
    vim.cmd.edit("mod.lua")
    changeset.open()
    settle()
    park_sidebar_cursor("other.lua")
    vim.cmd.edit("plain.lua")
    flush()

    changeset.toggle()

    assert.truthy(sidebar_cursor_line():find("other.lua", 1, true))
  end)

  it("lands on the nearest row on screen when yours is folded away", function()
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    changeset.open()
    settle()
    vim.api.nvim_set_current_win(window.win())
    park_sidebar_cursor("mod.lua")
    vim.cmd.normal("h")
    park_sidebar_cursor("other.lua")
    vim.cmd.wincmd("p")
    flush()

    changeset.toggle()

    assert.truthy(sidebar_cursor_line():find("mod.lua", 1, true))
  end)

  it("keeps the cursor on a landed row that you expand", function()
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    changeset.open()
    settle()
    vim.api.nvim_set_current_win(window.win())
    park_sidebar_cursor("mod.lua")
    vim.cmd.normal("h")
    vim.cmd.wincmd("p")
    flush()
    changeset.toggle()

    vim.cmd.normal("l")

    assert.truthy(sidebar_cursor_line():find("mod.lua", 1, true))
  end)

  it("steps from where the cursor is when the sidebar is the only window", function()
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    changeset.toggle()
    settle()
    park_sidebar_cursor("other.lua")
    local parked = vim.api.nvim_win_get_cursor(window.win())[1]
    vim.cmd.only()

    vim.cmd.normal("]h")

    assert.equal(parked + 1, vim.api.nvim_win_get_cursor(window.win())[1])
  end)

  it("leaves the cursor alone when a float entered from the sidebar closes", function()
    vim.cmd.edit("mod.lua")
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    changeset.toggle()
    settle()
    park_sidebar_cursor("other.lua")
    local float = vim.api.nvim_open_win(
      vim.api.nvim_create_buf(false, true),
      true,
      { relative = "editor", row = 1, col = 1, width = 10, height = 2 }
    )

    vim.api.nvim_win_close(float, true)

    assert.equal(window.win(), vim.api.nvim_get_current_win())
    assert.truthy(sidebar_cursor_line():find("other.lua", 1, true))
  end)

  describe("while symbols are still being read", function()
    local resolve = require("plugins.changeset.resolve")
    local real_start = resolve.start
    ---@type fun(path: string, items: table[]?)
    local answer

    ---A function spanning `first`..`last` of `mod.lua`, as a server would report it.
    local function symbol(name, first, last)
      return {
        name = name,
        text = name,
        kind = "Function",
        path = "mod.lua",
        lnum = first,
        col = 1,
        end_lnum = first,
        end_col = #name + 1,
        depth = 0,
        guides = "",
        range_lnum = first,
        range_end_lnum = last,
      }
    end

    ---Focus the sidebar from line 8 of `mod.lua` before its symbols are in.
    local function focus_before_symbols()
      vim.cmd.edit("mod.lua")
      vim.api.nvim_win_set_cursor(0, { 8, 0 })
      changeset.toggle()
      assert(
        vim.wait(10000, function()
          return window.buf() and sidebar_text():find("other.lua", 1, true)
        end, 25),
        "the diff never arrived"
      )
    end

    before_each(function()
      resolve.start = function(_, _, on_file)
        answer = on_file
        return function() end
      end
    end)

    after_each(function()
      resolve.start = real_start
    end)

    it("lands on the file row, then follows you into your symbol once it resolves", function()
      focus_before_symbols()
      assert.truthy(sidebar_cursor_line():find("mod.lua", 1, true))

      answer("mod.lua", { symbol("step", 7, 9) })

      assert.truthy(sidebar_cursor_line():find("step", 1, true))
    end)

    it("stays where you moved the sidebar cursor when your symbol resolves", function()
      focus_before_symbols()
      park_sidebar_cursor("other.lua")

      answer("mod.lua", { symbol("step", 7, 9) })

      assert.truthy(sidebar_cursor_line():find("other.lua", 1, true))
    end)

    it("leaves the sidebar cursor alone when your symbol resolves after you left it", function()
      focus_before_symbols()
      vim.cmd.wincmd("p")

      answer("mod.lua", { symbol("step", 7, 9) })

      assert.truthy(sidebar_cursor_line():find("mod.lua", 1, true))
    end)

    it("lands on the file row when a filter hides your symbol", function()
      focus_before_symbols()
      answer("mod.lua", { symbol("step", 7, 9) })
      vim.api.nvim_feedkeys("fL2" .. vim.keycode("<CR>"), "xt", false)
      assert.equal("L2", changeset._tree().query)
      vim.cmd.wincmd("p")
      flush()

      changeset.toggle()

      assert.truthy(sidebar_cursor_line():find("mod.lua", 1, true))
    end)
  end)

  it("closes the focused sidebar on <leader>gp and hands focus back", function()
    vim.cmd.edit("mod.lua")
    local file_win = vim.api.nvim_get_current_win()
    changeset.toggle()
    settle()

    changeset.toggle()

    assert.is_nil(window.win())
    assert.equal(file_win, vim.api.nvim_get_current_win())
  end)
end)
