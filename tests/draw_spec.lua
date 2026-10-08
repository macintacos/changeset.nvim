vim.opt.rtp:prepend(require("support.deps").path("mini.icons"))
require("mini.icons").setup()

local changeset = require("changeset")
local build = require("changeset.build")
local comment_store = require("changeset.comment_store")
local draw = require("changeset.draw")
local sidebar_state = require("changeset.sidebar_state")
local window = require("changeset.window")
local Changes = require("support.changes")
local Fixture = require("support.git")
local Sidebar = require("support.sidebar")
local Symbols = require("support.symbols")

local FILES = { "a.lua", "b.lua", "c.lua", "d.lua", "e.lua" }

---Every extmark on `buf`, in every namespace, without the ids that tell two draws apart.
---@param buf integer
---@return string[] Sorted.
local function marks(buf)
  local out = vim.tbl_map(function(mark)
    mark[4].id = nil
    return vim.inspect({ mark[2], mark[3], mark[4] })
  end, vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true }))
  table.sort(out)
  return out
end

---@alias changeset.spec.Drawn { text: string[], marks: string[], view: { topline: integer, topfill: integer, lnum: integer } }

---The sidebar's text, marks and scroll as they stand.
---@return changeset.spec.Drawn
local function drawn()
  local buf = assert(window.buf())
  local view = vim.api.nvim_win_call(assert(window.win()), vim.fn.winsaveview)
  return {
    text = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
    marks = marks(buf),
    view = { topline = view.topline, topfill = view.topfill, lnum = view.lnum },
  }
end

---The sidebar as a draw from nothing would leave it.
---@return changeset.spec.Drawn
local function from_scratch()
  draw._forget()
  draw.draw()
  return drawn()
end

---The 0-based line ranges each `nvim_buf_set_lines` on the sidebar replaced while `fn` ran.
---@param fn fun()
---@return { [1]: integer, [2]: integer }[]
local function set_ranges(fn)
  local buf, real, ranges = assert(window.buf()), vim.api.nvim_buf_set_lines, {}
  vim.api.nvim_buf_set_lines = function(b, first, last, strict, lines)
    if b == buf then
      ranges[#ranges + 1] = { first, last == -1 and vim.api.nvim_buf_line_count(b) or last }
    end
    return real(b, first, last, strict, lines)
  end
  local ok, err = pcall(fn)
  vim.api.nvim_buf_set_lines = real
  assert(ok, err)
  return ranges
end

---The 0-based line range `path`'s file row and the rows under it take on the sidebar.
---@param path string
---@return integer first, integer last Exclusive.
local function block_of(path)
  local first
  for i, row in ipairs(sidebar_state.current().view:visible()) do
    if first and row.depth <= 1 then
      return first, i - 1
    end
    if not first and row.kind == "file" and row.path == path then
      first = i - 1
    end
  end
  return assert(first), #sidebar_state.current().view:visible()
end

describe("changeset draw", function()
  local tmp, previous_dir, source

  before_each(function()
    tmp, previous_dir = Fixture.enter_tempdir()
    local base, change = {}, {}
    for _, path in ipairs(FILES) do
      base[path] = Fixture.numbered(12)
      change[path] = Fixture.numbered(12, { [2] = true, [9] = true })
    end
    Fixture.feature(base, change, tmp)
    source = Symbols.install()
    vim.cmd.edit("a.lua")
    changeset.open()
    assert.is_true(vim.wait(10000, function()
      return #source.asks == 1 and window.buf() ~= nil and Sidebar.text():find("e.lua", 1, true) ~= nil
    end, 10))
  end)

  after_each(function()
    source.restore()
    changeset.close()
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
    os.remove(comment_store.path())
  end)

  ---@param path string
  local function answer(path)
    source.answer(path, {
      Changes.sym("one", "Function", 0, 1, 5),
      Changes.sym("inner", "Variable", 1, 2, 3),
      Changes.sym("two", "Method", 0, 7, 12),
      Changes.sym("deep", "Function", 1, 8, 11),
      Changes.sym("deeper", "Variable", 2, 9, 10),
    })
  end

  it("replaces only the lines of the file whose symbols landed", function()
    draw.draw()
    local first, last = block_of("c.lua")

    local ranges = set_ranges(function()
      answer("c.lua")
      draw.draw()
    end)

    assert.is_true(#ranges > 0)
    for _, range in ipairs(ranges) do
      assert.is_true(range[1] >= first and range[2] <= last, vim.inspect({ range, first, last }))
    end
  end)

  it("replaces only the lines of the file it folds", function()
    for _, path in ipairs(FILES) do
      answer(path)
    end
    draw.draw()
    local first, last = block_of("b.lua")

    local ranges = set_ranges(function()
      sidebar_state.current().view:step_out(first + 1)
      draw.draw()
    end)

    assert.is_true(#ranges > 0)
    for _, range in ipairs(ranges) do
      assert.is_true(range[1] >= first and range[2] <= last, vim.inspect({ range, first, last }))
    end
  end)

  it("holds no more memory after many draws with review comments than after a few", function()
    local root = vim.fn.resolve(tmp)
    for _, path in ipairs({ "a.lua", "b.lua" }) do
      for line = 1, 10 do
        comment_store.keep(root, { path = path, line = line, body = "a review comment on line " .. line })
      end
    end
    for _ = 1, 50 do
      draw.draw()
    end
    collectgarbage("collect")
    collectgarbage("collect")
    local before = collectgarbage("count")

    for _ = 1, 2000 do
      draw.draw()
    end
    collectgarbage("collect")
    collectgarbage("collect")

    local grown = collectgarbage("count") - before
    assert.is_true(grown < 500, ("grew %.0f KiB over 2000 draws"):format(grown))
  end)

  it("draws every line again once something else changed the sidebar's buffer", function()
    draw.draw()
    local buf = assert(window.buf())
    local count = vim.api.nvim_buf_line_count(buf)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(("x"):rep(count, "\n"), "\n"))
    vim.bo[buf].modifiable = false

    draw.draw()
    local after = drawn()

    assert.same(from_scratch(), after)
  end)

  it("leaves the sidebar as a draw from nothing would, whatever happened since", function()
    local win = assert(window.win())
    local queries = { "", "", "one", "de", "b.lua", "zzz" }
    local kinds = { {}, {}, { Variable = true }, { Function = true }, { Method = true, Variable = true } }
    local unanswered = vim.deepcopy(FILES)
    local root = vim.fn.resolve(tmp)
    local comments = {}
    local diffs = 0
    build.subscribe(function(event)
      if event == "diff" then
        diffs = diffs + 1
      end
    end)

    ---@type (fun(view: changeset.View, pick: fun(n: integer): integer))[]
    local steps = {
      function(view, pick)
        view:open(pick(#view:visible()))
      end,
      function(view, pick)
        view:step_out(pick(#view:visible()))
      end,
      function(view)
        view:fold_files(sidebar_state.current().rows)
      end,
      function(view)
        view:unfold_files()
      end,
      function(view, pick)
        view:narrow(queries[pick(#queries)])
      end,
      function(view, pick)
        view:hide(kinds[pick(#kinds)])
      end,
      function(_, pick)
        vim.api.nvim_win_set_width(win, 24 + pick(40))
      end,
      function(_, pick)
        if #unanswered > 0 then
          answer(table.remove(unanswered, pick(#unanswered)))
        end
      end,
      function(_, pick)
        local buf = assert(window.buf())
        vim.api.nvim_win_set_cursor(win, { pick(vim.api.nvim_buf_line_count(buf)), 0 })
      end,
      function(_, pick)
        vim.api.nvim_win_call(win, function()
          vim.fn.winrestview({ topline = pick(vim.api.nvim_buf_line_count(0)), topfill = pick(3) - 1 })
        end)
      end,
      function(_, pick)
        local comment = { path = FILES[pick(#FILES)], line = pick(12), body = "a review comment" }
        comment_store.keep(root, comment)
        comments[#comments + 1] = comment
      end,
      function(_, pick)
        if #comments > 0 then
          comment_store.drop(root, table.remove(comments, pick(#comments)))
        end
      end,
      function(_, pick)
        local path = FILES[pick(#FILES)]
        vim.fn.writefile(Fixture.numbered(12, { [2] = true, [9] = true, [pick(12)] = true }, "rewritten"), path)
        local before = diffs
        build.refresh()
        assert.is_true((vim.wait(5000, function()
          return diffs > before
        end, 5)))
        if not vim.tbl_contains(unanswered, path) then
          unanswered[#unanswered + 1] = path
        end
      end,
    }

    for seed = 1, 12 do
      math.randomseed(seed)
      for _ = 1, 15 do
        steps[math.random(#steps)](sidebar_state.current().view, math.random)
        draw.draw()
        Sidebar.flush()
      end
      local incremental = drawn()

      assert.same(from_scratch(), incremental, "seed " .. seed)
    end
  end)
end)

describe("changeset draw in a short sidebar", function()
  local tmp, previous_dir, source

  before_each(function()
    tmp, previous_dir = Fixture.enter_tempdir()
    for _, dir in ipairs({ "lua", "tests", "doc" }) do
      vim.fn.mkdir(dir, "p")
    end
    local base, change = {}, {}
    for _, path in ipairs({
      "lua/a.lua",
      "lua/b.lua",
      "lua/c.lua",
      "tests/a_spec.lua",
      "tests/b_spec.lua",
      "doc/guide.md",
    }) do
      base[path] = Fixture.numbered(12)
      change[path] = Fixture.numbered(12, { [2] = true, [9] = true })
    end
    Fixture.feature(base, change, tmp)
    source = Symbols.install()
    vim.cmd.edit("lua/a.lua")
    comment_store.keep(vim.fn.resolve(tmp), { path = "lua/a.lua", line = 2, body = "first" })
    changeset.open()
    assert.is_true(vim.wait(10000, function()
      return #source.asks >= 1 and window.buf() ~= nil and Sidebar.text():find("guide.md", 1, true) ~= nil
    end, 10))
    -- A drawer, or a sidebar sharing its column.
    vim.cmd("botright 12new")
    vim.cmd.wincmd("p")
    vim.api.nvim_win_set_height(assert(window.win()), 10)
  end)

  after_each(function()
    source.restore()
    changeset.close()
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
    os.remove(comment_store.path())
  end)

  it("keeps its view when a redraw rewrites its top line and the cursor sits on its last screen row", function()
    local win = assert(window.win())
    vim.wo[win].scrolloff = 0
    local view = sidebar_state.current().view
    view:step_out(1) -- the Comments section, folded to its header
    view:fold_files(sidebar_state.current().rows)
    draw.draw()
    Sidebar.flush()
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview({ topline = 1, topfill = 0 })
      vim.cmd("redraw")
      vim.api.nvim_win_set_cursor(win, { vim.fn.line("w$"), 0 })
    end)
    draw.draw()
    Sidebar.flush()
    local before = drawn().view

    comment_store.keep(build.current().root, { path = "lua/b.lua", line = 9, body = "second" })
    draw.draw()
    Sidebar.flush()

    assert.same(before, drawn().view)
  end)
end)
