local changeset = require("plugins.changeset")
local render = require("plugins.changeset.render")
local window = require("plugins.changeset.window")
local Fixture = require("support.git")

local ns = vim.api.nvim_get_namespaces()["changeset"]

---@param path string
---@param lines string[]
local function write(path, lines)
  vim.fn.writefile(lines, path)
end

---A repo on `trunk` with two files, then a `feature` branch that changes both.
---@param cwd string
local function init_feature_repo(cwd)
  Fixture.init_repo("trunk", cwd)

  write("mod.lua", { "local M = {}", "", "function M.one()", "  return 1", "end", "", "return M" })
  write("other.lua", { "return { a = 1 }" })
  Fixture.commit("base", cwd)

  Fixture.git({ "checkout", "-q", "-b", "feature" }, cwd)
  write("mod.lua", { "local M = {}", "", "function M.one()", "  return 2", "end", "", "return M" })
  write("other.lua", { "return { a = 1, b = 2 }" })
  Fixture.commit("change", cwd)
end

---@param buf integer
---@return string[]
local function lines_of(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---@return integer buf
local function open_sidebar()
  vim.cmd.edit("mod.lua")
  changeset.open()
  local buf
  vim.wait(10000, function()
    buf = window.buf()
    return buf and #lines_of(buf) > 1
  end, 25)
  assert(buf, "the sidebar never opened a buffer")

  -- Symbols land after the diff does, replacing each file's placeholder row with
  -- however many rows it really has. A count taken before that settles drifts on
  -- its own, and every assertion below compares counts.
  local settled = vim.wait(10000, function()
    return not table.concat(lines_of(buf), "\n"):find("reading symbols", 1, true)
  end, 25)
  assert(settled, "symbols never finished resolving")
  return buf
end

---@param key string
local function press(key)
  vim.api.nvim_set_current_win(window.win())
  vim.cmd.normal(key)
end

describe("changeset sidebar", function()
  local tmp, previous_dir

  -- The sidebar resolves its repo from the process cwd, and `write` above takes
  -- relative paths, so the fixture has to be entered rather than merely pointed at.
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

  it("lists every file the branch changed", function()
    local text = table.concat(lines_of(open_sidebar()), "\n")

    assert.truthy(text:find("mod.lua", 1, true))
    assert.truthy(text:find("other.lua", 1, true))
  end)

  it("marks the lines it rendered", function()
    local buf = open_sidebar()

    -- Counting row marks rather than every mark in the namespace: the hidden-kinds
    -- note is the one virtual line that lands here without a row behind it, and a
    -- bare count would pass on that alone.
    local row_marks = vim.tbl_filter(function(mark)
      return mark[4].virt_lines == nil
    end, vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }))

    assert.truthy(#row_marks > 0)
  end)

  -- `render` sits a filter match one above `MARK_PRIORITY`, which only holds while
  -- the marks it outranks are stamped at `MARK_PRIORITY` here.
  it("stamps a mark that carries no priority of its own at the default", function()
    local buf = open_sidebar()

    local row_mark = vim.tbl_filter(function(mark)
      return mark[4].hl_group ~= nil
    end, vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }))[1]

    assert.equal(render.MARK_PRIORITY, row_mark[4].priority)
  end)

  it("leads a nested file's row with its filename and dims its directory", function()
    vim.fn.mkdir("lua/pkg", "p")
    write("lua/pkg/nested.lua", { "return {}" })
    Fixture.commit("nested", tmp)
    local buf = open_sidebar()

    local lnum, line
    for i, text in ipairs(lines_of(buf)) do
      if text:find("nested.lua (lua/pkg)", 1, true) then
        lnum, line = i - 1, text
      end
    end
    assert(line, "no row reads `nested.lua (lua/pkg)`")
    local col = line:find("(lua/pkg)", 1, true) - 1
    local dim_marks = vim.tbl_filter(function(mark)
      return mark[4].hl_group == "Comment" and mark[3] == col and mark[4].end_col == col + #"(lua/pkg)"
    end, vim.api.nvim_buf_get_extmarks(buf, ns, { lnum, 0 }, { lnum, -1 }, { details = true }))
    assert.equal(1, #dim_marks)
  end)

  it("names what the branch is compared against in the window bar", function()
    open_sidebar()

    assert.truthy(vim.wo[window.win()].winbar:find("trunk", 1, true))
  end)

  it("totals the branch above the tree, scrolled into view", function()
    local buf = open_sidebar()

    local above = vim.tbl_filter(function(mark)
      return mark[4].virt_lines_above
    end, vim.api.nvim_buf_get_extmarks(buf, ns, 0, 0, { details = true }))
    assert.equal(1, #above)
    local text = table.concat(vim.tbl_map(function(chunk)
      return chunk[1]
    end, above[1][4].virt_lines[1]))
    assert.truthy(text:find("2 files", 1, true))
    -- Lines above the first only show as filler, which nothing scrolls in unasked.
    assert.truthy(vim.api.nvim_win_call(window.win(), vim.fn.winsaveview).topfill > 0)
  end)

  -- No language server runs under the specs, so neither fixture file gets an answer.
  it("asks again about a file no server answered for only once it changes", function()
    open_sidebar()
    local resolve = require("plugins.changeset.resolve")
    local start = resolve.start
    local asked
    resolve.start = function(root, files, on_file)
      asked = vim.tbl_map(function(file)
        return file.path
      end, files)
      return start(root, files, on_file)
    end
    local function refreshed()
      asked = nil
      changeset.refresh()
      assert(
        vim.wait(5000, function()
          return asked ~= nil
        end, 10),
        "the refresh never reached the symbols"
      )
      return asked
    end

    local ok, err = pcall(function()
      assert.same({}, refreshed())
      write("other.lua", { "return { a = 1, b = 2, c = 3 }" })
      assert.same({ "other.lua" }, refreshed())
    end)
    resolve.start = start
    assert(ok, err)
  end)

  it("footers the sidebar with the file the cursor is in", function()
    open_sidebar()
    local win = window.win()
    vim.api.nvim_win_set_cursor(win, { 1, 0 })

    local footer = vim.api.nvim_eval_statusline(vim.wo[win].statusline, { winid = win }).str

    assert.truthy(footer:find("Changeset", 1, true))
    assert.truthy(footer:find("file 1 of 2", 1, true))
  end)

  it("shuts every file, then opens them again", function()
    local buf = open_sidebar()
    local expanded = #lines_of(buf)

    press("H")
    local collapsed = #lines_of(buf)
    press("L")

    assert.truthy(collapsed < expanded)
    assert.equal(expanded, #lines_of(buf))
  end)

  ---@class changeset.spec.Previewed
  ---@field target integer The window the previews went to.
  ---@field from_buf integer What that window held before the sidebar opened.
  ---@field from_lnum integer
  ---@field from_winbar string
  ---@field previewed integer The buffer the preview put there.

  ---Open the sidebar from `mod.lua` and walk the selection `steps` rows with `]h`,
  ---pressed with the cursor `from` the sidebar or the file window, where it stays.
  ---Asserts the previews left the jumplist and the buffer list alone.
  ---@param steps integer
  ---@param from "sidebar"|"file"
  ---@return changeset.spec.Previewed
  local function preview(steps, from)
    vim.cmd.edit("mod.lua")
    local target = vim.api.nvim_get_current_win()
    local staged = {
      target = target,
      from_buf = vim.api.nvim_win_get_buf(target),
      from_lnum = vim.api.nvim_win_get_cursor(target)[1],
      from_winbar = vim.wo[target].winbar,
    }
    open_sidebar()
    if from == "sidebar" then
      vim.api.nvim_set_current_win(window.win())
    end
    local standing = vim.api.nvim_get_current_win()
    local before = vim.fn.getjumplist(target)[1]
    local listed = #vim.fn.getbufinfo({ buflisted = 1 })

    for _ = 1, steps do
      vim.cmd.normal("]h")
    end

    assert.same(before, vim.fn.getjumplist(target)[1])
    assert.equal(listed, #vim.fn.getbufinfo({ buflisted = 1 }))
    assert.equal(standing, vim.api.nvim_get_current_win())
    -- From the sidebar, the band is the proof a preview landed at all: without it
    -- an untouched jumplist would also pass when `]h` did nothing. From the file,
    -- the callers prove it by the buffer instead, since the window being read has none.
    if from == "sidebar" then
      assert.truthy(vim.wo[target].winbar ~= "")
    end
    staged.previewed = vim.api.nvim_win_get_buf(target)
    return staged
  end

  ---Preview `steps` rows from the sidebar, then commit with `enter`. Asserts the
  ---commit opened the previewed file where it stood, with `<C-o>` pointing at the
  ---pre-sidebar position.
  ---@param steps integer
  ---@param enter fun() Commits the preview, starting with the cursor in the sidebar.
  local function commit_after(steps, enter)
    local p = preview(steps, "sidebar")
    local previewed_lnum = vim.api.nvim_win_get_cursor(p.target)[1]

    enter()

    assert.equal(p.previewed, vim.api.nvim_win_get_buf(p.target))
    assert.is_true(vim.bo[p.previewed].buflisted)
    assert.equal(p.from_winbar, vim.wo[p.target].winbar)
    assert.equal(previewed_lnum, vim.api.nvim_win_get_cursor(p.target)[1])
    local jumps = vim.fn.getjumplist(p.target)[1]
    local last_jump = jumps[#jumps]
    assert.truthy(last_jump, "the commit recorded no jumplist entry, so <C-o> has nowhere to go")
    assert.equal(p.from_buf, last_jump.bufnr)
    assert.equal(p.from_lnum, last_jump.lnum)
  end

  local function press_enter()
    vim.cmd.normal(vim.keycode("<CR>"))
  end

  local function back_to_previous_window()
    vim.cmd.wincmd("p")
  end

  it("previews without touching the jumplist, and sends <C-o> back to where the sidebar opened", function()
    commit_after(3, press_enter)
  end)

  -- One `]h` stays inside the file the sidebar was opened from, where the commit
  -- re-shows the buffer the window already holds, so no buffer swap records the
  -- jump and the commit has to.
  it("sends <C-o> back for a row in the file the sidebar was opened from", function()
    commit_after(1, press_enter)
  end)

  it("commits a preview the cursor moves into, and sends <C-o> back to where the sidebar opened", function()
    commit_after(3, back_to_previous_window)
  end)

  it("keeps the file a focused preview claimed when the sidebar closes", function()
    local p = preview(3, "sidebar")
    assert.are_not.equal(p.from_buf, p.previewed)

    back_to_previous_window()
    changeset.close()

    assert.equal(p.previewed, vim.api.nvim_win_get_buf(p.target))
  end)

  it("leaves a preview made where the cursor stands a preview when focus comes back to it", function()
    local p = preview(3, "file")
    assert.are_not.equal(p.from_buf, p.previewed)

    local float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 10,
      height = 1,
    })
    vim.api.nvim_win_close(float, true)
    changeset.close()

    assert.equal(p.from_buf, vim.api.nvim_win_get_buf(p.target))
    assert.is_false(vim.bo[p.previewed].buflisted)
  end)

  it("puts a preview back when the sidebar is closed with :q", function()
    local p = preview(3, "sidebar")
    assert.are_not.equal(p.from_buf, p.previewed)

    vim.cmd.quit()
    vim.wait(1000, function()
      return vim.api.nvim_win_get_buf(p.target) == p.from_buf
    end, 10)

    assert.equal(p.from_buf, vim.api.nvim_win_get_buf(p.target))
    assert.is_false(vim.bo[p.previewed].buflisted)
  end)

  describe("on a file the branch deleted", function()
    before_each(function()
      Fixture.git({ "rm", "-q", "other.lua" }, tmp)
      Fixture.commit("drop other", tmp)
    end)

    ---Open the sidebar from `mod.lua` and move its cursor onto the deleted row.
    ---@return integer target The window the preview goes to.
    local function on_deleted_row()
      vim.cmd.edit("mod.lua")
      local target = vim.api.nvim_get_current_win()
      local buf = open_sidebar()
      local lnum
      for i, line in ipairs(lines_of(buf)) do
        if line:find("other.lua", 1, true) then
          lnum = i
          break
        end
      end
      assert(lnum, "the deleted file has no row")
      vim.api.nvim_set_current_win(window.win())
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
      return target
    end

    ---@return boolean
    local function deleted_file_loaded()
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.endswith(vim.api.nvim_buf_get_name(buf), "/other.lua") then
          return true
        end
      end
      return false
    end

    it("previews a notice that the file was deleted", function()
      local target = on_deleted_row()

      local text = table.concat(lines_of(vim.api.nvim_win_get_buf(target)), "\n")
      assert.truthy(text:find("This file was deleted on this branch", 1, true))
    end)

    it("opens nothing for the deleted file on <CR>", function()
      on_deleted_row()

      vim.cmd.normal(vim.keycode("<CR>"))

      assert.is_false(deleted_file_loaded())
    end)

    it("chooses nothing when the cursor moves into the notice", function()
      local target = on_deleted_row()
      local notice = vim.api.nvim_win_get_buf(target)
      local listed = #vim.fn.getbufinfo({ buflisted = 1 })

      vim.cmd.wincmd("p")

      assert.equal(target, vim.api.nvim_get_current_win())
      assert.equal(notice, vim.api.nvim_win_get_buf(target))
      assert.equal(listed, #vim.fn.getbufinfo({ buflisted = 1 }))
    end)
  end)

  it("filters on a query the pattern matcher would choke on", function()
    local buf = open_sidebar()
    vim.api.nvim_set_current_win(window.win())

    -- Not `press`: `vim.fn.input` blocks, so the keys it consumes have to be in the
    -- typeahead before `f` runs. `x` mode drains what is already queued.
    vim.api.nvim_feedkeys(vim.keycode("f(<CR>"), "xt", false)

    -- `(` matches no row, so `draw` falls through to the empty message. Under a
    -- pattern-mode `find` the filter raises instead and the tree is left standing.
    assert.equal(1, #lines_of(buf))
    assert.falsy(table.concat(lines_of(buf), "\n"):find("other.lua", 1, true))
  end)

  it("shuts the row under the cursor", function()
    local buf = open_sidebar()
    local expanded = #lines_of(buf)

    press("h")

    assert.truthy(#lines_of(buf) < expanded)
  end)
end)
