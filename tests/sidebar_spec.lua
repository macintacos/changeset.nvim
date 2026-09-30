vim.opt.rtp:prepend(require("support.deps").path("mini.icons"))
require("mini.icons").setup()

local changeset = require("changeset")
changeset.setup({ keymaps = { next = "]h", prev = "[h" } })
local render = require("changeset.render")
local window = require("changeset.window")
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

---The first sidebar line containing `text` below line `after`.
---@param buf integer
---@param text string
---@param after integer?
---@return integer
local function line_of(buf, text, after)
  for i, line in ipairs(lines_of(buf)) do
    if i > (after or 0) and line:find(text, 1, true) then
      return i
    end
  end
  error("no sidebar line contains " .. text)
end

---@return integer buf
local function open_sidebar()
  vim.cmd.edit("mod.lua")
  changeset.open()
  local buf
  vim.wait(10000, function()
    buf = window.buf()
    return buf ~= nil and #lines_of(buf) > 1
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

---The branch totals drawn above the tree.
---@param buf integer
---@return string
local function totals(buf)
  local above = vim.tbl_filter(function(mark)
    return mark[4].virt_lines_above
  end, vim.api.nvim_buf_get_extmarks(buf, ns, 0, 0, { details = true }))
  assert.equal(1, #above)
  return table.concat(vim.tbl_map(function(chunk)
    return chunk[1]
  end, above[1][4].virt_lines[1]))
end

---@param key string
local function press(key)
  local win = assert(window.win())
  vim.api.nvim_set_current_win(win)
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

    assert.truthy(totals(buf):find("2 files", 1, true))
    -- Lines above the first only show as filler, which nothing scrolls in unasked.
    assert.truthy(vim.api.nvim_win_call(assert(window.win()), vim.fn.winsaveview).topfill > 0)
  end)

  it("redraws the tree across the bottom of the editor once it narrows", function()
    local columns = vim.o.columns
    vim.o.columns = 200
    local buf = open_sidebar()

    vim.o.columns = 100
    vim.api.nvim_exec_autocmds("VimResized", {})
    local width = vim.fn.strdisplaywidth(totals(buf))
    vim.o.columns = columns

    assert.equal(100, width)
  end)

  it("keeps the tree clear of a statuscolumn, whose cells its rows are sized over", function()
    local statuscolumn = vim.o.statuscolumn
    vim.o.statuscolumn = "%l "
    open_sidebar()
    -- `textoff` is measured as the window is drawn.
    vim.cmd.redraw({ bang = true })
    vim.o.statuscolumn = statuscolumn
    local win = window.win()

    assert.equal(0, vim.fn.getwininfo(win)[1].textoff)
  end)

  it("wraps the sentence it shows in place of an empty tree, but not the tree", function()
    open_sidebar()
    assert.is_false(vim.wo[assert(window.win())].wrap)

    Fixture.git({ "checkout", "-q", "trunk" }, tmp)
    changeset.open()
    local buf = assert(window.buf())
    assert(
      vim.wait(5000, function()
        return lines_of(buf)[1]:find("nothing to compare", 1, true) ~= nil
      end, 10),
      "the sidebar never emptied"
    )

    assert.is_true(vim.wo[assert(window.win())].wrap)
  end)

  -- No language server runs under the specs, so neither fixture file gets an answer.
  it("asks again about a file no server answered for only once it changes", function()
    open_sidebar()
    local resolve = require("changeset.resolve")
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
    local win = assert(window.win())
    vim.api.nvim_win_set_cursor(win, { 2, 0 })

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

  it("folds files under H but never a section header", function()
    local buf = open_sidebar()

    press("H")

    assert.truthy(lines_of(buf)[1]:find("Implementation", 1, true))
    assert.equal(3, #lines_of(buf))
  end)

  describe("with a second section", function()
    before_each(function()
      write("README.md", { "# readme" })
      Fixture.commit("docs", tmp)
    end)

    ---Rebuild the tree and wait until the Docs section is drawn or gone.
    ---@param buf integer
    ---@param shown boolean
    local function refresh_until(buf, shown)
      changeset.refresh()
      assert(vim.wait(5000, function()
        return (table.concat(lines_of(buf), "\n"):find("Docs", 1, true) ~= nil) == shown
      end, 25))
    end

    it("moves between section headers with ]] and [[, stopping at either end", function()
      local buf = open_sidebar()
      vim.api.nvim_set_current_win((assert(window.win())))
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      press("]]")
      assert.equal(line_of(buf, "Docs"), vim.api.nvim_win_get_cursor(0)[1])
      press("]]")
      assert.equal(line_of(buf, "Docs"), vim.api.nvim_win_get_cursor(0)[1])
      press("[[")
      assert.equal(1, vim.api.nvim_win_get_cursor(0)[1])
      press("[[")
      assert.equal(1, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("lands on a folded section's header", function()
      local buf = open_sidebar()
      vim.api.nvim_set_current_win((assert(window.win())))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      press("h")
      vim.api.nvim_win_set_cursor(0, { line_of(buf, "README.md"), 0 })

      press("[[")
      assert.equal(line_of(buf, "Docs"), vim.api.nvim_win_get_cursor(0)[1])
      press("[[")
      assert.equal(1, vim.api.nvim_win_get_cursor(0)[1])
      press("]]")
      assert.equal(line_of(buf, "Docs"), vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("keeps ]] over a buffer-local ]] another plugin sets at FileType", function()
      local group = vim.api.nvim_create_augroup("changeset.spec.filetype_map", { clear = true })
      -- Stands in for a plugin that maps `]]` on every buffer as its filetype is set.
      vim.api.nvim_create_autocmd("FileType", {
        group = group,
        callback = function(args)
          vim.keymap.set("n", "]]", "<Nop>", { buffer = args.buf })
        end,
      })
      local buf = open_sidebar()
      vim.api.nvim_del_augroup_by_id(group)
      vim.api.nvim_set_current_win((assert(window.win())))
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      press("]]")

      assert.equal(line_of(buf, "Docs"), vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("lists ]] and [[ under ?", function()
      open_sidebar()

      press("?")

      local float = vim.iter(vim.api.nvim_list_wins()):find(function(win)
        return vim.api.nvim_win_get_config(win).relative ~= ""
      end)
      local text = table.concat(lines_of(vim.api.nvim_win_get_buf((assert(float)))), "\n")
      assert.truthy(text:find("%]%]%s+Next section"))
      assert.truthy(text:find("%[%[%s+Previous section"))
    end)

    it("leaves a folded section folded under L", function()
      local buf = open_sidebar()
      vim.api.nvim_set_current_win((assert(window.win())))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      press("h")

      press("L")

      local text = lines_of(buf)
      assert.falsy(table.concat(text, "\n"):find("mod.lua", 1, true))
      assert.truthy(table.concat(text, "\n"):find("README.md", 1, true))
    end)

    it("leaves a folded section folded under L while the section is empty", function()
      local buf = open_sidebar()
      vim.api.nvim_set_current_win((assert(window.win())))
      vim.api.nvim_win_set_cursor(0, { line_of(buf, "Docs"), 0 })
      press("h")
      Fixture.git({ "rm", "-q", "README.md" }, tmp)
      Fixture.commit("no docs", tmp)
      refresh_until(buf, false)

      press("L")
      write("README.md", { "# readme" })
      Fixture.commit("docs again", tmp)
      refresh_until(buf, true)

      assert.falsy(table.concat(lines_of(buf), "\n"):find("README.md", 1, true))
    end)

    it("draws the gap between sections without a buffer line", function()
      local buf = open_sidebar()

      press("H")

      local above = line_of(buf, "Docs") - 2
      local gaps = vim.tbl_filter(function(mark)
        return mark[4].virt_lines ~= nil
      end, vim.api.nvim_buf_get_extmarks(buf, ns, { above, 0 }, { above, -1 }, { details = true }))
      assert.equal(2 + 3, #lines_of(buf))
      assert.equal(1, #gaps)
    end)

    it("previews the next section's first file with ]h from a section's last line", function()
      vim.cmd.edit("mod.lua")
      local target = vim.api.nvim_get_current_win()
      local buf = open_sidebar()
      vim.api.nvim_set_current_win((assert(window.win())))
      vim.api.nvim_win_set_cursor(0, { line_of(buf, "Docs") - 1, 0 })

      press("]h")

      assert.equal(line_of(buf, "README.md"), vim.api.nvim_win_get_cursor(0)[1])
      assert.truthy(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(target)):find("README.md$"))
    end)
  end)

  describe("with inline tests", function()
    local resolve = require("changeset.resolve")
    local real_start = resolve.start
    ---@type fun(path: string, items: table[]?)
    local answer

    ---A symbol spanning `first`..`last` of `path`, as a server would report it.
    ---@param s { path: string, name: string, kind: string, depth: integer, first: integer, last: integer }
    local function sym(s)
      return {
        name = s.name,
        text = s.name,
        kind = s.kind,
        path = s.path,
        lnum = s.first,
        col = 1,
        end_lnum = s.first,
        end_col = #s.name + 1,
        depth = s.depth,
        guides = "",
        range_lnum = s.first,
        range_end_lnum = s.last,
      }
    end

    local SESSION = {
      sym({ path = "src/session.rs", name = "load", kind = "Function", depth = 0, first = 1, last = 3 }),
      sym({ path = "src/session.rs", name = "tests", kind = "Module", depth = 0, first = 5, last = 9 }),
      sym({ path = "src/session.rs", name = "refreshes", kind = "Function", depth = 1, first = 6, last = 8 }),
    }
    local ONLY_TESTS = {
      sym({ path = "src/only_tests.rs", name = "tests", kind = "Module", depth = 0, first = 1, last = 5 }),
      sym({ path = "src/only_tests.rs", name = "works", kind = "Function", depth = 1, first = 2, last = 4 }),
    }

    ---@return integer
    local function tests_header()
      return line_of(assert(window.buf()), "Tests")
    end

    ---@param lnum integer
    local function cursor_to(lnum)
      local win = assert(window.win())
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { lnum, 0 })
    end

    ---@return integer
    local function cursor_line()
      return vim.api.nvim_win_get_cursor((assert(window.win())))[1]
    end

    local function flush()
      local flushed = false
      vim.schedule(function()
        flushed = true
      end)
      vim.wait(1000, function()
        return flushed
      end)
    end

    ---Open from `mod.lua` so "you are here" stays out of the `.rs` files, and wait for the diff alone.
    local function open_unanswered()
      vim.cmd.edit("mod.lua")
      changeset.open()
      assert(
        vim.wait(10000, function()
          local buf = window.buf()
          return buf ~= nil and table.concat(lines_of(buf), "\n"):find("session.rs", 1, true) ~= nil
        end, 25),
        "the diff never arrived"
      )
    end

    local function answer_all()
      answer("mod.lua", {})
      answer("other.lua", {})
      answer("src/only_tests.rs", ONLY_TESTS)
      answer("src/session.rs", SESSION)
      flush()
    end

    ---@return string
    local function footer()
      local win = assert(window.win())
      return vim.api.nvim_eval_statusline(vim.wo[win].statusline, { winid = win }).str
    end

    before_each(function()
      vim.fn.mkdir("src", "p")
      write("src/session.rs", {
        "fn load() {",
        "    let a = 1;",
        "}",
        "",
        "mod tests {",
        "    fn refreshes() {",
        "        let b = 1;",
        "    }",
        "}",
      })
      write("src/only_tests.rs", { "mod tests {", "    fn works() {", "        let c = 1;", "    }", "}" })
      Fixture.commit("rust", tmp)
      resolve.start = function(_, _, on_file)
        answer = on_file
        return function() end
      end
    end)

    after_each(function()
      resolve.start = real_start
    end)

    it("keeps the cursor on a split file's own copy when its tests land under Tests", function()
      open_unanswered()
      cursor_to(line_of(assert(window.buf()), "session.rs"))

      answer("src/session.rs", SESSION)
      flush()

      assert.truthy(tests_header() < line_of(assert(window.buf()), "session.rs", tests_header()))
      assert.equal(line_of(assert(window.buf()), "session.rs"), cursor_line())
      assert.truthy(cursor_line() < tests_header())
    end)

    it("follows a file whose changes are all tests into Tests", function()
      open_unanswered()
      cursor_to(line_of(assert(window.buf()), "only_tests.rs"))

      answer("src/only_tests.rs", ONLY_TESTS)
      flush()

      assert.equal(line_of(assert(window.buf()), "only_tests.rs"), cursor_line())
      assert.truthy(cursor_line() > tests_header())
    end)

    it("folds each copy of a split file on its own", function()
      open_unanswered()
      answer_all()

      cursor_to(line_of(assert(window.buf()), "session.rs", tests_header()))
      press("h")
      line_of(assert(window.buf()), "load")
      assert.has_error(function()
        line_of(assert(window.buf()), "refreshes")
      end)

      press("l")
      cursor_to(line_of(assert(window.buf()), "session.rs"))
      press("h")
      line_of(assert(window.buf()), "refreshes")
      assert.has_error(function()
        line_of(assert(window.buf()), "load")
      end)
    end)

    it("numbers a split file once, at its first row, on both copies", function()
      open_unanswered()
      answer_all()

      local impl = line_of(assert(window.buf()), "session.rs")
      assert.truthy(line_of(assert(window.buf()), "mod.lua") < line_of(assert(window.buf()), "other.lua"))
      assert.truthy(line_of(assert(window.buf()), "other.lua") < impl and impl < tests_header())
      assert.truthy(tests_header() < line_of(assert(window.buf()), "only_tests.rs"))
      assert.truthy(
        line_of(assert(window.buf()), "only_tests.rs") < line_of(assert(window.buf()), "session.rs", tests_header())
      )

      cursor_to(impl)
      assert.truthy(footer():find("file 3 of 4", 1, true))
      cursor_to(line_of(assert(window.buf()), "session.rs", tests_header()))
      assert.truthy(footer():find("file 3 of 4", 1, true))
    end)

    describe("on the Tests copy's symbol", function()
      it("opens its line on <CR>", function()
        open_unanswered()
        answer_all()
        cursor_to(line_of(assert(window.buf()), "refreshes"))

        press(vim.keycode("<CR>"))

        assert.truthy(vim.api.nvim_buf_get_name(0):find("src/session.rs$"))
        assert.equal(6, vim.api.nvim_win_get_cursor(0)[1])
      end)

      it("yanks the file's path and its line, as the other copy's rows do", function()
        open_unanswered()
        answer_all()
        local Paths = require("changeset.paths")
        local copy = Paths.copy
        local yanked = {}
        Paths.copy = function(text)
          table.insert(yanked, text)
        end

        local ok, err = pcall(function()
          cursor_to(line_of(assert(window.buf()), "refreshes"))
          press("y")
          cursor_to(line_of(assert(window.buf()), "session.rs"))
          press("y")
          cursor_to(line_of(assert(window.buf()), "session.rs", tests_header()))
          press("y")
        end)
        Paths.copy = copy
        assert(ok, err)
        assert.same({ "src/session.rs:6", "src/session.rs:1", "src/session.rs:1" }, yanked)
      end)

      it("previews its line", function()
        local target = vim.api.nvim_get_current_win()
        open_unanswered()
        answer_all()

        cursor_to(line_of(assert(window.buf()), "refreshes"))
        vim.api.nvim_exec_autocmds("CursorMoved", { buffer = window.buf() })

        assert.truthy(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(target)):find("src/session.rs$"))
        assert.equal(6, vim.api.nvim_win_get_cursor(target)[1])
      end)
    end)

    it("files a cached symbol the syntax marked under Tests without asking about the file again", function()
      local cache = require("changeset.cache")
      local root = assert(vim.uv.fs_realpath(tmp))
      local cache_file = cache.path(root)
      cache.save(cache_file, {
        ["src/session.rs"] = {
          stamp = assert(cache.stamp(root .. "/src/session.rs")),
          symbols = {
            { name = "load", kind = "Function", depth = 0, lnum = 1, range_lnum = 1, range_end_lnum = 3, test = true },
            { name = "tests", kind = "Module", depth = 0, lnum = 5, range_lnum = 5, range_end_lnum = 9 },
            { name = "refreshes", kind = "Function", depth = 1, lnum = 6, range_lnum = 6, range_end_lnum = 8 },
          },
        },
      })
      local asked = {}
      resolve.start = function(_, files, on_file)
        answer = on_file
        for _, f in ipairs(files) do
          asked[#asked + 1] = f.path
        end
        return function() end
      end

      local ok, err = pcall(function()
        open_unanswered()
        for _, path in ipairs(asked) do
          answer(path, {})
        end
        flush()

        assert.truthy(tests_header() < line_of(assert(window.buf()), "load"))
        assert.is_false(vim.tbl_contains(asked, "src/session.rs"))
      end)
      vim.fn.delete(cache_file)
      assert(ok, err)
    end)

    describe("while a kind is hidden", function()
      local prefs = require("changeset.prefs")

      ---The text of each virtual line hung under a buffer line, with the 0-based line it hangs from.
      ---@param buf integer
      ---@return { text: string, line: integer }[]
      local function notes_under(buf)
        local notes = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
          local virt_lines = mark[4].virt_lines
          local text = virt_lines and not mark[4].virt_lines_above and virt_lines[#virt_lines][1][1]
          -- A section's trailing blank is a virtual line too.
          if text and text ~= "" then
            notes[#notes + 1] = { text = text, line = mark[2] }
          end
        end
        return notes
      end

      before_each(function()
        assert(prefs.save(prefs.path(), { global = { "Function" } }), "could not save the hidden kinds")
      end)

      after_each(function()
        vim.fn.delete(prefs.path())
        changeset.setup({ keymaps = { next = "]h", prev = "[h" } })
      end)

      it("notes under the tree which kinds it is hiding", function()
        open_unanswered()
        answer_all()
        local buf = assert(window.buf())

        local notes = notes_under(buf)
        assert.equal(1, #notes)
        assert.truthy(notes[1].text:find("functions", 1, true))
        assert.equal(#lines_of(buf) - 1, notes[1].line)
      end)

      it("names the key it bound to the kind menu in that note", function()
        changeset.setup({ keymaps = { next = "]h", prev = "[h", filter_kinds = "<C-k>" } })
        open_unanswered()
        answer_all()

        local notes = notes_under(assert(window.buf()))
        assert.equal(1, #notes)
        assert.truthy(notes[1].text:find("<C-k>", 1, true))
      end)
    end)
  end)

  describe("with generated files", function()
    before_each(function()
      write("go.sum", { "example.com/m v1.0.0 h1:abc=" })
      write("schema.txt", { "generated schema" })
      write(".gitattributes", { "schema.txt linguist-generated" })
      Fixture.commit("generated", tmp)
    end)

    ---Whether a file row names `path`, not merely a line mentioning it: `.gitattributes`' orphan row is captioned with its `schema.txt` line.
    ---@param buf integer
    ---@param path string
    ---@return boolean
    local function shows(buf, path)
      return vim.iter(lines_of(buf)):any(function(line)
        return vim.endswith(line, " " .. path)
      end)
    end

    ---@param buf integer
    local function unfold(buf)
      vim.api.nvim_set_current_win((assert(window.win())))
      vim.api.nvim_win_set_cursor(0, { line_of(buf, "Generated"), 0 })
      press("l")
    end

    it("starts folded, below every other section", function()
      local buf = open_sidebar()

      assert.equal(#lines_of(buf), line_of(buf, "Generated"))
      assert.is_false(shows(buf, "go.sum"))
      assert.is_false(shows(buf, "schema.txt"))
    end)

    it("stays unfolded for the repository once l opens it", function()
      local buf = open_sidebar()
      unfold(buf)
      assert.is_true(shows(buf, "go.sum"))

      changeset.close()
      -- A new branch builds a new session over the same fold state, which must not fold Generated again.
      Fixture.git({ "checkout", "-q", "-b", "other" }, tmp)
      buf = open_sidebar()

      assert.is_true(shows(buf, "go.sum"))
    end)

    it("stays folded under L", function()
      local buf = open_sidebar()

      press("L")

      assert.is_false(shows(buf, "go.sum"))
    end)

    it("never asks for a generated file's symbols, nor waits on them", function()
      local resolve = require("changeset.resolve")
      local start = resolve.start
      local asked = {}
      resolve.start = function(_, files)
        for _, f in ipairs(files) do
          asked[#asked + 1] = f.path
        end
        return function() end
      end

      local ok, err = pcall(function()
        -- Not open_sidebar(): it waits for `reading symbols` to clear, which this stub never answers.
        vim.cmd.edit("mod.lua")
        changeset.open()
        local buf
        assert(
          vim.wait(10000, function()
            buf = window.buf()
            return buf ~= nil and pcall(line_of, buf, "Generated")
          end, 25),
          "the Generated section never appeared"
        )
        unfold(buf)
        local lines = lines_of(buf)

        assert.truthy(vim.tbl_contains(asked, "mod.lua"))
        assert.is_false(vim.tbl_contains(asked, "go.sum"))
        assert.is_false(vim.tbl_contains(asked, "schema.txt"))
        assert.falsy((lines[line_of(buf, "go.sum") + 1] or ""):find("reading symbols", 1, true))
        assert.truthy(lines[line_of(buf, "mod.lua") + 1]:find("reading symbols", 1, true))
      end)
      resolve.start = start
      assert(ok, err)
    end)
  end)

  describe("on a section header", function()
    ---Open the sidebar from `mod.lua` with its cursor on the first header.
    ---@return integer buf
    local function on_header()
      vim.cmd.edit("mod.lua")
      local buf = open_sidebar()
      vim.api.nvim_set_current_win((assert(window.win())))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      return buf
    end

    it("folds its section with h and unfolds it with l", function()
      local buf = on_header()
      local expanded = #lines_of(buf)

      press("h")
      assert.equal(1, #lines_of(buf))
      press("l")

      assert.equal(expanded, #lines_of(buf))
    end)

    it("keeps its section folded through a close and a reopen", function()
      local buf = on_header()
      press("h")

      changeset.close()
      buf = open_sidebar()

      assert.equal(1, #lines_of(buf))
    end)

    it("is where h goes from a shut file", function()
      on_header()
      press("H")
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      press("h")

      assert.equal(1, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("leaves the file window alone when the cursor moves onto it", function()
      local buf = on_header()
      local target = vim.fn.win_getid(vim.fn.winnr("#"))
      local before = vim.api.nvim_win_get_buf(target)

      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })

      assert.equal(before, vim.api.nvim_win_get_buf(target))
    end)

    it("opens nothing, copies nothing and says nothing on <CR> or y", function()
      on_header()
      local Paths = require("changeset.paths")
      local commit, copy, notify = window.commit, Paths.copy, vim.notify
      local calls = {}
      window.commit = function()
        table.insert(calls, "commit")
      end
      Paths.copy = function()
        table.insert(calls, "copy")
      end
      vim.notify = function(msg)
        table.insert(calls, msg)
      end

      local ok, err = pcall(function()
        press(vim.keycode("<CR>"))
        press("y")
      end)
      window.commit, Paths.copy, vim.notify = commit, copy, notify
      assert(ok, err)
      assert.same({}, calls)
    end)
  end)

  it("hands the picker one file row per changed file", function()
    open_sidebar()

    local rows = assert(changeset.rows()).rows

    assert.same(
      { "file", "file" },
      vim.tbl_map(function(row)
        return row.kind
      end, rows)
    )
  end)

  it("draws a section header's icon from mini.icons' directory icons", function()
    local buf = open_sidebar()
    local glyph, hl = MiniIcons.get("directory", "src")

    local marks = vim.tbl_filter(function(mark)
      return mark[4].hl_group == hl
    end, vim.api.nvim_buf_get_extmarks(buf, ns, { 0, 0 }, { 0, 0 }, { details = true }))

    assert.equal(1, #marks)
    assert.equal(glyph, lines_of(buf)[1]:sub(1, #glyph))
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
      local win = assert(window.win())
      vim.api.nvim_set_current_win(win)
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
    assert.not_equal(p.from_buf, p.previewed)

    back_to_previous_window()
    changeset.close()

    assert.equal(p.previewed, vim.api.nvim_win_get_buf(p.target))
  end)

  it("leaves a preview made where the cursor stands a preview when focus comes back to it", function()
    local p = preview(4, "file")
    assert.not_equal(p.from_buf, p.previewed)

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
    assert.not_equal(p.from_buf, p.previewed)

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
      local win = assert(window.win())
      vim.api.nvim_set_current_win(win)
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
    local win = assert(window.win())
    vim.api.nvim_set_current_win(win)

    -- Not `press`: `vim.fn.input` blocks, so the keys it consumes have to be in the
    -- typeahead before `f` runs. `x` mode drains what is already queued.
    vim.api.nvim_feedkeys(vim.keycode("f(<CR>"), "xt", false)

    -- `(` matches no row, so `draw` falls through to the empty message. Under a
    -- pattern-mode `find` the filter raises instead and the tree is left standing.
    assert.equal(1, #lines_of(buf))
    assert.falsy(table.concat(lines_of(buf), "\n"):find("other.lua", 1, true))
  end)
end)
