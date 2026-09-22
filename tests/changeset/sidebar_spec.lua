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

  it("summarises the branch in the window bar", function()
    open_sidebar()

    assert.truthy(vim.wo[window.win()].winbar:find("%d"))
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

  ---Walk the selection `steps` rows with `]h`, commit it, and assert the previews
  ---left the jumplist alone while `<CR>` pointed `<C-o>` at the pre-sidebar position.
  ---@param steps integer
  local function commit_after(steps)
    vim.cmd.edit("mod.lua")
    local target = vim.api.nvim_get_current_win()
    local from_buf = vim.api.nvim_win_get_buf(target)
    local from_lnum = vim.api.nvim_win_get_cursor(target)[1]
    open_sidebar()
    local before = vim.fn.getjumplist(target)[1]

    for _ = 1, steps do
      vim.cmd.normal("]h")
    end

    assert.same(before, vim.fn.getjumplist(target)[1])
    assert.equal(target, vim.api.nvim_get_current_win())
    -- The band is the proof a preview landed at all: without it an untouched
    -- jumplist would also pass when `]h` did nothing.
    assert.truthy(vim.wo[target].winbar ~= "")

    vim.api.nvim_set_current_win(window.win())
    vim.cmd.normal(vim.keycode("<CR>"))

    local jumps = vim.fn.getjumplist(target)[1]
    local last_jump = jumps[#jumps]
    assert.truthy(last_jump, "<CR> recorded no jumplist entry, so <C-o> has nowhere to go")
    assert.equal(from_buf, last_jump.bufnr)
    assert.equal(from_lnum, last_jump.lnum)
  end

  it("previews without touching the jumplist, and sends <C-o> back to where the sidebar opened", function()
    commit_after(3)
  end)

  -- One `]h` stays inside the file the sidebar was opened from, where the commit
  -- re-shows the buffer the window already holds, so no buffer swap records the
  -- jump and the commit has to.
  it("sends <C-o> back for a row in the file the sidebar was opened from", function()
    commit_after(1)
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
