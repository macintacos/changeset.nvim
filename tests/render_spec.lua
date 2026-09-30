local render = require("changeset.render")

---@param overrides? table
---@return changeset.Row
local function file(overrides)
  return vim.tbl_extend("force", {
    id = "src/a.lua",
    kind = "file",
    depth = 0,
    name = "src/a.lua",
    path = "src/a.lua",
    status = "modified",
    added = 12,
    removed = 3,
    ancestor = false,
    resolved = true,
    children = {},
  }, overrides or {})
end

---@param overrides? table
---@return changeset.Row
local function symbol(overrides)
  return vim.tbl_extend("force", {
    id = "src/a.lua\0Foo",
    kind = "symbol",
    depth = 1,
    name = "Foo",
    path = "src/a.lua",
    lnum = 3,
    symbol_kind = "Function",
    added = 8,
    removed = 1,
    ancestor = false,
    children = {},
  }, overrides or {})
end

---@param overrides? table
---@return changeset.Row
local function section(overrides)
  return vim.tbl_extend("force", {
    id = "#implementation",
    kind = "section",
    depth = 0,
    name = "Implementation",
    path = "",
    icon = "src",
    files = 1,
    added = 12,
    removed = 3,
    ancestor = false,
    children = { file() },
  }, overrides or {})
end

---@param overrides? table
---@return table
local function opts(overrides)
  return vim.tbl_extend("force", {
    icon = function(row)
      return row.kind == "file" and "F" or "S", "IconHl"
    end,
    collapsed = function()
      return false
    end,
    width = 80,
  }, overrides or {})
end

---The mark whose highlight covers exactly `covered` in the line's text.
---@param line changeset.Line
---@param covered string
---@return changeset.Mark?
local function mark_over(line, covered)
  for _, mark in ipairs(line.marks) do
    if mark.end_col and line.text:sub(mark.col + 1, mark.end_col) == covered then
      return mark
    end
  end
end

---@param lines changeset.Line[]
---@return string[]
local function texts(lines)
  return vim.tbl_map(function(line)
    return line.text
  end, lines)
end

---The virtual-text mark of a line, if it has one.
---@param line changeset.Line
---@return changeset.Mark?
local function stat_mark(line)
  for _, mark in ipairs(line.marks) do
    if mark.virt_text then
      return mark
    end
  end
end

---The lines `files` draw under a section's header, the header itself left out.
---@param files changeset.Row[]
---@param options table
---@return changeset.Line[]
local function file_lines(files, options)
  return vim.list_slice(render.lines({ section({ children = files }) }, options), 2)
end

describe("changeset.render", function()
  describe("section rows", function()
    it("heads a section with its label and file count", function()
      local one = render.lines({ section() }, opts())[1]
      local two = render.lines({ section({ files = 2 }) }, opts())[1]

      assert.truthy(one.text:find("Implementation", 1, true))
      assert.truthy(one.text:find("1 file$"))
      assert.truthy(two.text:find("2 files$"))
    end)

    it("starts every header's count in the same column", function()
      local lines = render.lines({ section(), section({ id = "#docs", name = "Docs" }) }, opts())

      assert.equal(lines[1].text:find("1 file"), lines[3].text:find("1 file"))
    end)

    it("shrinks the label's padding so a wide stat clears the count", function()
      local wide = section({ files = 123, added = 15234, removed = 8123 })
      local narrow = render.lines({ wide }, opts({ width = 42 }))[1]

      assert.is_true(vim.fn.strdisplaywidth(narrow.text) + #"+15234 -8123" + 1 <= 42)
    end)

    it("draws the label as plain content", function()
      local line = render.lines({ section() }, opts())[1]

      for _, mark in ipairs(line.marks) do
        assert.is_false(mark.end_col ~= nil and line.text:sub(mark.col + 1, mark.end_col):find("Implementation") ~= nil)
      end
    end)

    it("draws the file count in the meta group", function()
      local line = render.lines({ section({ files = 2 }) }, opts())[1]

      assert.equal(render.META_HL, mark_over(line, "2 files").hl)
    end)

    it("draws the header's icon in the group the caller gives it", function()
      local line = render.lines({ section() }, opts())[1]

      assert.equal("IconHl", mark_over(line, "S").hl)
    end)

    it("right-aligns the section's stat", function()
      local mark = assert(stat_mark(render.lines({ section() }, opts())[1]))

      assert.equal("right_align", mark.pos)
      assert.equal("+12", mark.virt_text[1][1])
    end)

    it("draws no rail on a section header", function()
      local line = render.lines({ section() }, opts())[1]

      assert.is_nil(line.text:find("▎", 1, true))
    end)

    it("draws only the header of a folded section", function()
      local lines = render.lines(
        { section() },
        opts({
          collapsed = function(id)
            return id == "#implementation"
          end,
        })
      )

      assert.equal(1, #lines)
    end)

    it("hangs a blank line under every section but the last", function()
      local docs = section({ id = "#docs", name = "Docs", children = { file({ id = "#docs\0b.md" }) } })
      local lines = render.lines({ section(), docs }, opts())

      local function separators(line)
        return #vim.tbl_filter(function(mark)
          return mark.virt_lines ~= nil
        end, line.marks)
      end
      assert.same({ 0, 1, 0, 0 }, vim.tbl_map(separators, lines))
    end)

    it("does not mark a filter match on a header", function()
      local line = render.lines({ section() }, opts({ query = "impl" }))[1]

      assert.is_nil(mark_over(line, "Impl"))
    end)
  end)

  describe("lines", function()
    describe("file rows", function()
      local rails = {
        added = "GitSignsAdd",
        modified = "GitSignsChange",
        deleted = "GitSignsDelete",
        untracked = "GitSignsUntracked",
        renamed = "GitSignsChange",
      }
      for status, hl in pairs(rails) do
        it(("draws the rail in %s for status '%s'"):format(hl, status), function()
          local lines = file_lines({ file({ status = status }) }, opts())

          assert.equal("▎", lines[1].text:sub(1, #"▎"))
          assert.same({ col = 0, end_col = #"▎", hl = hl }, mark_over(lines[1], "▎"))
        end)
      end

      it("puts the icon, coloured by the caller's group, between the rail and the filename", function()
        local lines = file_lines({ file() }, opts())

        assert.equal("▎ F a.lua (src)", lines[1].text)
        assert.equal("IconHl", mark_over(lines[1], "F").hl)
      end)

      it("dims the directory after the filename", function()
        local lines = file_lines({ file() }, opts())

        local mark = assert(mark_over(lines[1], "(src)"))
        assert.equal("Comment", mark.hl)
        assert.is_nil(mark.priority)
      end)

      it("draws a file at the repository root with no directory", function()
        local lines = file_lines({ file({ path = "a.lua" }) }, opts())

        assert.equal("▎ F a.lua", lines[1].text)
      end)

      for _, status in ipairs({ "deleted", "renamed" }) do
        it(("ends a file with status '%s' with a Comment marker"):format(status), function()
          local lines = file_lines({ file({ status = status }) }, opts())

          assert.equal("▎ F a.lua (src) " .. status, lines[1].text)
          assert.equal("Comment", mark_over(lines[1], " " .. status).hl)
        end)
      end

      for _, status in ipairs({ "added", "modified", "untracked" }) do
        it(("adds no marker for status '%s'"):format(status), function()
          local lines = file_lines({ file({ status = status }) }, opts())

          assert.equal("▎ F a.lua (src)", lines[1].text)
        end)
      end
    end)

    describe("symbol rows", function()
      it("hangs a connector off each sibling, closing the last", function()
        local rows = {
          file({ children = { symbol({ name = "Alpha" }), symbol({ name = "Beta" }) } }),
        }

        assert.same({ "▎ F a.lua (src)", "  ├─S Alpha", "  └─S Beta" }, texts(file_lines(rows, opts())))
      end)

      it("carries a bar down under a parent with later siblings, and blank under the last", function()
        local rows = {
          file({
            children = {
              symbol({ name = "First", children = { symbol({ name = "Inner" }) } }),
              symbol({ name = "Last", children = { symbol({ name = "Tail" }) } }),
            },
          }),
        }

        assert.same({
          "▎ F a.lua (src)",
          "  ├─S First",
          "  │ └─S Inner",
          "  └─S Last",
          "    └─S Tail",
        }, texts(file_lines(rows, opts())))
      end)

      it("draws the connectors in Comment", function()
        local lines = file_lines({ file({ children = { symbol() } }) }, opts())

        assert.equal("Comment", mark_over(lines[2], "└─").hl)
      end)

      it("colours the kind icon with the caller's group", function()
        local lines = file_lines({ file({ children = { symbol() } }) }, opts())

        assert.equal("IconHl", mark_over(lines[2], "S").hl)
      end)

      it("draws an ancestor's name in Comment but keeps its icon colour", function()
        local ancestor = symbol({ name = "Container", ancestor = true })
        local lines = file_lines({ file({ children = { ancestor } }) }, opts())

        assert.equal("Comment", mark_over(lines[2], "Container").hl)
        assert.equal("IconHl", mark_over(lines[2], "S").hl)
      end)
    end)

    describe("stats", function()
      local function right_aligned(line, added, removed)
        return {
          col = #line.text,
          pos = "right_align",
          hl_mode = "combine",
          virt_text = { { "+" .. added, "GitSignsAdd" }, { " " }, { "-" .. removed, "GitSignsDelete" }, { "  " } },
        }
      end

      it("right-aligns +N in GitSignsAdd and -N in GitSignsDelete on a file row", function()
        local lines = file_lines({ file({ added = 12, removed = 3 }) }, opts())

        assert.same(right_aligned(lines[1], 12, 3), stat_mark(lines[1]))
      end)

      it("right-aligns them on a symbol row too", function()
        local rows = { file({ children = { symbol({ added = 8, removed = 1 }) } }) }
        local lines = file_lines(rows, opts())

        assert.same(right_aligned(lines[2], 8, 1), stat_mark(lines[2]))
      end)

      for _, counts in ipairs({ { 2, 0 }, { 0, 5 } }) do
        local added, removed = counts[1], counts[2]
        it(("shows +%d -%d rather than dropping the zero"):format(added, removed), function()
          local lines = file_lines({ file({ added = added, removed = removed }) }, opts())

          assert.same(right_aligned(lines[1], added, removed), stat_mark(lines[1]))
        end)
      end

      it("emits no stat for a row that carries none", function()
        local bare = symbol()
        bare.added, bare.removed = nil, nil
        local lines = file_lines({ file({ children = { bare } }) }, opts())

        assert.is_nil(stat_mark(lines[2]))
      end)

      it("emits no stat for an ancestor, even when numbers were left on it", function()
        local ancestor = symbol({ ancestor = true, added = 8, removed = 1 })
        local lines = file_lines({ file({ children = { ancestor } }) }, opts())

        assert.is_nil(stat_mark(lines[2]))
      end)
    end)

    describe("state_marks", function()
      ---@param state "selected"|"here"|"picked"
      ---@return vim.api.keyset.set_extmark tint, vim.api.keyset.set_extmark glyph
      local function marks(state)
        local tint, glyph
        for _, mark in ipairs(render.state_marks(state, 44)) do
          if mark.virt_text then
            glyph = mark
          else
            tint = mark
          end
        end
        return assert(tint), assert(glyph)
      end

      it("tints the selected row to the window's edge, its glyph in the last column", function()
        local tint, glyph = marks("selected")

        assert.same(
          { render.SELECTED_HL, true, render.SELECTED_ICON, 43 },
          { tint.hl_group, tint.hl_eol, glyph.virt_text[1][1], glyph.virt_text_win_col }
        )
      end)

      it("marks the row you are on the same way, in its own tint and glyph", function()
        local tint, glyph = marks("here")

        assert.same(
          { render.HERE_HL, true, render.HERE_ICON, 43 },
          { tint.hl_group, tint.hl_eol, glyph.virt_text[1][1], glyph.virt_text_win_col }
        )
      end)

      it("marks the row you last opened the same way, in its own tint and glyph", function()
        local tint, glyph = marks("picked")

        assert.same(
          { render.PICKED_HL, true, render.PICKED_ICON, 43 },
          { tint.hl_group, tint.hl_eol, glyph.virt_text[1][1], glyph.virt_text_win_col }
        )
      end)

      it("tints beneath every row mark, so a filter match still shows over it", function()
        local tint = marks("selected")

        assert.is_true(tint.priority < render.MARK_PRIORITY)
      end)

      it("draws the glyph over the stat, whose blank tail would otherwise hide it", function()
        local _, glyph = marks("selected")

        assert.is_true(glyph.priority > render.MARK_PRIORITY)
        assert.equal("combine", glyph.hl_mode)
      end)

      it("sets the glyph in the blank a row's stat ends with, a cell clear of the numbers", function()
        local lines = file_lines({ file({ added = 12, removed = 3 }) }, opts({ width = 44 }))
        local stat = assert(assert(stat_mark(lines[1])).virt_text)
        local tail = stat[#stat][1]
        local _, glyph = marks("selected")

        assert.equal("", vim.trim(tail))
        assert.is_true(glyph.virt_text_win_col > 44 - #tail and glyph.virt_text_win_col < 44)
      end)
    end)

    describe("symbols still resolving", function()
      it("adds a placeholder child under a file whose children have not arrived", function()
        local lines = file_lines({ file({ resolved = false }) }, opts())

        assert.same({ "▎ F a.lua (src)", "  └─⋯ reading symbols" }, texts(lines))
        assert.equal(render.META_HL, mark_over(lines[2], "⋯ reading symbols").hl)
      end)

      it("shows only the file row once a file is resolved but nothing inside it changed", function()
        local lines = file_lines({ file({ resolved = true }) }, opts())

        assert.same({ "▎ F a.lua (src)" }, texts(lines))
      end)

      it("nests the placeholder under the file as a row of its own", function()
        local lines = file_lines({ file({ resolved = false }) }, opts())

        assert.not_equal(lines[1].row.id, lines[2].row.id)
        assert.equal(lines[1].row.depth + 1, lines[2].row.depth)
        assert.equal("src/a.lua", lines[2].row.path)
      end)

      it("shows no placeholder for a deleted file, whose subtree is empty by design", function()
        local lines = file_lines({ file({ status = "deleted" }) }, opts())

        assert.same({ "▎ F a.lua (src) deleted" }, texts(lines))
      end)
    end)

    describe("orphan hunks", function()
      local function with_orphans()
        local hunk = symbol({ id = "src/a.lua\0#orphans\0#orphan:4", kind = "orphan", name = "L4–6 local x = 1" })
        local group =
          symbol({ id = "src/a.lua\0#orphans", kind = "orphans", name = "Other changes", children = { hunk } })
        return { file({ children = { group } }) }
      end

      it("draws the group and its hunks in the meta group", function()
        local lines = file_lines(with_orphans(), opts())

        assert.equal(render.META_HL, mark_over(lines[2], "Other changes").hl)
        assert.equal(render.META_HL, mark_over(lines[3], "L4–6 local x = 1").hl)
      end)

      it("dims their icon instead of using the caller's colour", function()
        local lines = file_lines(with_orphans(), opts())

        assert.equal(render.META_HL, mark_over(lines[2], "S").hl)
      end)
    end)

    describe("collapsing", function()
      local function collapsed_ids(...)
        local ids = {}
        for _, id in ipairs({ ... }) do
          ids[id] = true
        end
        return function(id)
          return ids[id] == true
        end
      end

      it("hides everything under a collapsed file", function()
        local rows = { file({ children = { symbol() } }) }
        local lines = file_lines(rows, opts({ collapsed = collapsed_ids("src/a.lua") }))

        assert.same({ "▎ F a.lua (src)" }, texts(lines))
      end)

      it("hides the placeholder of a collapsed file still resolving", function()
        local lines = file_lines({ file({ resolved = false }) }, opts({ collapsed = collapsed_ids("src/a.lua") }))

        assert.same({ "▎ F a.lua (src)" }, texts(lines))
      end)

      it("pairs each line with the row it draws, in display order, omitting what a collapsed file hides", function()
        local rows = {
          file({ id = "a.lua", path = "a.lua", children = { symbol({ id = "a-hidden" }) } }),
          file({
            id = "b.lua",
            path = "b.lua",
            children = {
              symbol({ id = "b-outer", children = { symbol({ id = "b-nested" }) } }),
              symbol({ id = "b-next" }),
            },
          }),
        }
        local lines = file_lines(rows, opts({ collapsed = collapsed_ids("a.lua") }))

        local ids = vim.tbl_map(function(line)
          return line.row.id
        end, lines)
        assert.same({ "a.lua", "b.lua", "b-outer", "b-nested", "b-next" }, ids)
      end)

      it("hides only the subtree of a collapsed symbol, keeping it and its siblings", function()
        local inner = symbol({ id = "inner", name = "Inner" })
        local rows = {
          file({
            children = { symbol({ id = "outer", name = "Outer", children = { inner } }), symbol({ name = "Next" }) },
          }),
        }
        local lines = file_lines(rows, opts({ collapsed = collapsed_ids("outer") }))

        assert.same({ "▎ F a.lua (src)", "  ├─S Outer", "  └─S Next" }, texts(lines))
      end)
    end)

    describe("fitting to the window width", function()
      it("trims a long symbol chain from the left so its stat stays on screen", function()
        local chain = symbol({ name = "SessionStore › refresh › deadline", added = 8, removed = 1 })
        local lines = file_lines({ file({ children = { chain } }) }, opts({ width = 30 }))

        assert.equal("  └─S … › deadline", lines[2].text)
        assert.not_nil(stat_mark(lines[2]))
      end)

      it("trims a long directory from the left, keeping the whole filename and the marker", function()
        local deleted = file({ status = "deleted", path = "very/long/dir/structure/deleted_file.lua" })
        deleted.added, deleted.removed = nil, nil
        local lines = file_lines({ deleted }, opts({ width = 46 }))

        assert.equal("▎ F deleted_file.lua (…/structure) deleted", lines[1].text)
      end)

      it("drops the directory when the filename leaves no room for it", function()
        local deleted = file({ status = "deleted", path = "very/long/dir/structure/deleted_file.lua" })
        deleted.added, deleted.removed = nil, nil
        local lines = file_lines({ deleted }, opts({ width = 30 }))

        assert.equal("▎ F deleted_file.lua deleted", lines[1].text)
      end)

      it("trims an orphan hunk from the right, keeping its line range", function()
        local hunk = symbol({ kind = "orphan", name = "L4–6 local x = 1 + something long" })
        hunk.added, hunk.removed = nil, nil
        local lines = file_lines({ file({ children = { hunk } }) }, opts({ width = 30 }))

        assert.equal("  └─S L4–6 local x = 1 + so…", lines[2].text)
      end)
    end)
  end)

  describe("filter highlighting", function()
    it("marks the characters a filter query matched", function()
      local lines = file_lines({ file() }, opts({ query = "a.lua" }))

      local mark = assert(mark_over(lines[1], "a.lua"))

      assert.equal(render.MATCH_HL, mark.hl)
    end)

    -- An ancestor row, which is the case with a colour of its own to sit under:
    -- it is dimmed to `Comment`, and a match on it still has to read.
    it("draws the match over the colour the row already carries", function()
      local rows = { file({ children = { symbol({ name = "Alpha", ancestor = true }) } }) }

      local lines = file_lines(rows, opts({ query = "lph" }))

      local match = assert(mark_over(lines[2], "lph"))
      local name = assert(mark_over(lines[2], "Alpha"))

      assert.is_nil(name.priority)
      assert.is_true(match.priority > render.MARK_PRIORITY)
    end)

    it("takes the query as plain text, not as a pattern", function()
      local lines = file_lines({ file({ path = "a(b).lua" }) }, opts({ query = "(" }))

      local mark = assert(mark_over(lines[1], "("))

      assert.equal(render.MATCH_HL, mark.hl)
    end)

    it("leaves the rows unmarked when nothing is being filtered", function()
      local lines = file_lines({ file() }, opts())

      for _, mark in ipairs(lines[1].marks) do
        assert.not_equal(render.MATCH_HL, mark.hl)
      end
    end)
  end)

  describe("header", function()
    local LONG = "origin/jt/exc-1200-stacked-parent-branch-with-a-long-name"

    ---@param summary table
    ---@param width integer?
    ---@param highlights boolean?
    ---@return { str: string, highlights: table[]? }
    local function eval(summary, width, highlights)
      width = width or 44
      return vim.api.nvim_eval_statusline(
        render.header(summary, width),
        { use_winbar = true, maxwidth = width, highlights = highlights }
      )
    end

    ---The group drawing the first byte of `needle` in an evaluated statusline.
    ---@param shown { str: string, highlights: table[]? }
    ---@param needle string
    ---@return string?
    local function group_at(shown, needle)
      local at = shown.str:find(needle, 1, true) - 1
      local found
      for _, mark in ipairs(assert(shown.highlights)) do
        if mark.start <= at then
          found = mark.group
        end
      end
      return found
    end

    it("names what the tree is compared against", function()
      assert.truthy(eval({ ref = "origin/trunk" }).str:find("origin/trunk", 1, true))
    end)

    it("keeps the head of a ref too long to fit, marking the cut at its end", function()
      local text = eval({ ref = LONG }, 30).str

      assert.truthy(text:find("origin/jt/exc-1200", 1, true))
      assert.truthy(vim.endswith(vim.trim(text), "…"))
      -- The statusline marks a cut of its own with `<`, and keeps the tail.
      assert.falsy(text:find("<", 1, true))
    end)

    it("names the branch's open PR at the right edge", function()
      assert.equal(" #412", eval({ ref = "origin/trunk", pr = 412 }).str:sub(-5))
    end)

    it("gives up the ref's tail rather than the PR number", function()
      local text = eval({ ref = LONG, pr = 412 }, 30).str

      assert.equal(" #412", text:sub(-5))
      assert.truthy(text:find("origin/jt", 1, true))
      assert.truthy(text:find("…", 1, true))
      assert.falsy(text:find("<", 1, true))
    end)

    it("escapes % in the ref so the statusline does not read it as an item", function()
      assert.truthy(eval({ ref = "origin/50%off" }).str:find("origin/50%off", 1, true))
    end)

    it("dims the remote so the branch name leads", function()
      render.define_highlights()
      local shown = eval({ ref = "origin/trunk" }, 44, true)

      assert.equal(render.HEADER_DIM_HL, group_at(shown, "origin/"))
      assert.equal(render.HEADER_REF_HL, group_at(shown, "trunk"))
    end)

    it("reads a local ref whole, with nothing dimmed", function()
      render.define_highlights()
      local shown = eval({ ref = "jt/parent" }, 44, true)

      assert.equal(render.HEADER_REF_HL, group_at(shown, "jt/parent"))
    end)
  end)

  describe("header_totals", function()
    local BASE = { ref = "origin/trunk", files = 7, added = 142, removed = 38 }

    ---@param overrides table?
    ---@return table[] chunks
    local function totals(overrides)
      return render.header_totals(vim.tbl_extend("force", BASE, overrides or {}), 44)
    end

    ---@param chunks table[]
    ---@return string
    local function text(chunks)
      return table.concat(vim.tbl_map(function(chunk)
        return chunk[1]
      end, chunks))
    end

    it("counts the files, saying '1 file' for one", function()
      assert.truthy(text(totals()):find("7 files", 1, true))
      assert.truthy(text(totals({ files = 1 })):find("1 file", 1, true))
      assert.falsy(text(totals({ files = 1 })):find("1 files", 1, true))
    end)

    it("counts the branch's commits, saying '1 commit' for one", function()
      assert.truthy(text(totals({ commits = 3 })):find("3 commits", 1, true))
      assert.falsy(text(totals({ commits = 1 })):find("1 commits", 1, true))
      assert.truthy(text(totals({ commits = 1 })):find("1 commit", 1, true))
    end)

    it("sets the commits beside the line totals", function()
      assert.truthy(text(totals({ commits = 3 })):find("3 commits  +142 -38", 1, true))
    end)

    it("leaves commits out when there are none to count", function()
      assert.falsy(text(totals()):find("commit", 1, true))
      assert.falsy(text(totals({ commits = 0 })):find("commit", 1, true))
    end)

    it("ends the line totals in the column the rows' stats end in, filling the width", function()
      local line = text(totals())
      local row = file_lines({ file({ added = 142, removed = 38 }) }, opts({ width = 44 }))[1]
      local stat = table.concat(vim.tbl_map(function(chunk)
        return chunk[1]
      end, assert(stat_mark(row)).virt_text))

      assert.truthy(vim.endswith(line, " " .. stat))
      assert.equal(44, vim.fn.strdisplaywidth(line))
    end)

    it("reports symbols being read in place of the counts on the left", function()
      local line = text(totals({ commits = 3, reading = { done = 12, total = 28 } }))

      assert.truthy(line:find("reading symbols 12/28", 1, true))
      assert.falsy(line:find("files", 1, true))
      assert.falsy(line:find("commit", 1, true))
      assert.truthy(line:find(" +142 -38", 1, true))
    end)

    it("draws every chunk on the header's strip", function()
      vim.api.nvim_set_hl(0, "ChangesetSpecStrip", { bg = 0x654321 })
      local tabline = vim.api.nvim_get_hl(0, { name = "TabLine" })
      vim.api.nvim_set_hl(0, "TabLine", { link = "ChangesetSpecStrip" })
      render.define_highlights()

      for _, chunk in ipairs(totals({ commits = 3 })) do
        -- A stack of groups takes each attribute from the last group that sets it.
        local bg
        for _, name in ipairs(type(chunk[2]) == "table" and chunk[2] or { chunk[2] }) do
          bg = vim.api.nvim_get_hl(0, { name = name, link = false }).bg or bg
        end
        assert.equal(0x654321, bg)
      end
      vim.api.nvim_set_hl(0, "TabLine", tabline --[[@as vim.api.keyset.highlight]])
    end)

    it("colours the totals the way the rows colour theirs", function()
      local by_text = {}
      for _, chunk in ipairs(totals()) do
        by_text[chunk[1]] = chunk[2]
      end

      assert.same({ render.HEADER_HL, "GitSignsAdd" }, by_text["+142"])
      assert.same({ render.HEADER_HL, "GitSignsDelete" }, by_text["-38"])
    end)
  end)

  describe("footer", function()
    ---@param info table
    ---@return string
    local function shown(info)
      local keys = { jump = "<CR>", filter = "f", filter_kinds = "F", help = "?" }
      local full = vim.tbl_extend("force", { files = 12, query = "", keys = keys }, info)
      return vim.api.nvim_eval_statusline(render.footer(full), { maxwidth = 120 }).str
    end

    it("says which of the files shown the cursor is in", function()
      assert.truthy(shown({ file = 3 }):find("file 3 of 12", 1, true))
    end)

    it("leaves the position out when the cursor is in no file", function()
      assert.falsy(shown({}):find(" of 12", 1, true))
    end)

    it("shows the filter in force", function()
      assert.truthy(shown({ query = "sess" }):find("sess", 1, true))
    end)

    it("escapes % in the filter so the statusline does not read it as an item", function()
      assert.truthy(shown({ query = "50%" }):find("50%", 1, true))
    end)

    it("points at ? for every key, at the right edge", function()
      assert.truthy(vim.endswith(shown({}), "? all keys "))
    end)

    it("names a remapped key, escaping %", function()
      local footer = shown({ keys = { jump = "o%", filter = "f", filter_kinds = "F", help = "?" } })

      assert.truthy(footer:find("o% open", 1, true))
      assert.falsy(footer:find("<CR>", 1, true))
    end)

    it("leaves out a key set to false", function()
      local footer = shown({ keys = { jump = "<CR>", filter = false, filter_kinds = "F", help = "?" } })

      assert.falsy(footer:find("filter", 1, true))
      assert.truthy(footer:find("F kinds", 1, true))
    end)
  end)

  describe("preview_winbar", function()
    ---@param destination string?
    ---@param path string?
    ---@param jump (string|false)?
    ---@return changeset.Band
    local function band(destination, path, jump)
      return {
        jump = jump == nil and "<CR>" or jump,
        icon = "󰢱",
        -- What `band_icon` hands back, which is the only group a real band carries.
        icon_hl = render.PREVIEW_ICON_HL,
        destination = destination,
        path = path or "lua/init.lua",
      }
    end

    it("escapes % in the path so the statusline does not read it as an item", function()
      assert.is_true(render.preview_winbar(band(nil, "a/50%off.md")):find("50%%off", 1, true) ~= nil)
    end)

    it("carries the file's own icon in front of the path", function()
      local shown =
        vim.api.nvim_eval_statusline(render.preview_winbar(band()), { use_winbar = true, maxwidth = 70 }).str

      assert.is_true(shown:find("󰢱 lua/init.lua", 1, true) ~= nil)
    end)

    it("names what <CR> lands on at the right edge", function()
      local shown = vim.api.nvim_eval_statusline(
        render.preview_winbar(band("SessionStore › refresh")),
        { use_winbar = true, maxwidth = 70 }
      ).str

      assert.is_true(vim.endswith(shown, "SessionStore › refresh "))
    end)

    it("offers the way out instead when the row names nothing to land on", function()
      local shown =
        vim.api.nvim_eval_statusline(render.preview_winbar(band()), { use_winbar = true, maxwidth = 70 }).str

      assert.is_true(vim.endswith(shown, "<CR> to open "))
    end)

    it("offers a remapped jump key, escaping %", function()
      local shown = vim.api.nvim_eval_statusline(
        render.preview_winbar(band(nil, nil, "o%")),
        { use_winbar = true, maxwidth = 70 }
      ).str

      assert.is_true(vim.endswith(shown, "o% to open "))
    end)

    it("offers no way out when jump is unbound", function()
      local shown = vim.api.nvim_eval_statusline(
        render.preview_winbar(band(nil, nil, false)),
        { use_winbar = true, maxwidth = 70 }
      ).str

      assert.is_nil(shown:find("to open", 1, true))
    end)

    it("gives up the path first when the window is too narrow for all three", function()
      local shown = vim.api.nvim_eval_statusline(
        render.preview_winbar(band("refresh", "a/very/long/path/that/will/never/fit.lua")),
        { use_winbar = true, maxwidth = 26 }
      ).str

      assert.is_true(shown:find(" Preview ", 1, true) ~= nil)
      assert.is_true(vim.endswith(shown, "refresh "))
    end)

    it("draws the badge, the icon, the path and the way out as separate runs", function()
      render.define_highlights()
      render.band_icon("Comment")
      local shown = vim.api.nvim_eval_statusline(
        render.preview_winbar(band()),
        { use_winbar = true, maxwidth = 60, highlights = true }
      )

      assert.same(
        { render.PREVIEW_LABEL_HL, render.PREVIEW_ICON_HL, render.PREVIEW_HL, render.PREVIEW_HINT_HL },
        vim.tbl_map(function(mark)
          return mark.group
        end, shown.highlights)
      )
    end)

    it("fills the width, so the band spans the window", function()
      local shown = vim.api.nvim_eval_statusline(render.preview_winbar(band()), { use_winbar = true, maxwidth = 60 })

      assert.equal(60, vim.fn.strdisplaywidth(shown.str))
    end)
  end)

  describe("empty_message", function()
    it("tells you to switch branches when you are on the default branch", function()
      local info = { on_default_branch = true, branch = "main", ref = "origin/main" }

      assert.equal("On main — nothing to compare. Switch to a branch to see its changes.", render.empty_message(info))
    end)

    it("says a branch with no diff matches what it is compared against", function()
      local info = { on_default_branch = false, branch = "feat/x", ref = "origin/develop" }

      assert.equal("feat/x matches origin/develop. Nothing changed yet.", render.empty_message(info))
    end)
  end)

  describe("define_highlights", function()
    local GROUP_NAMES = {
      "Comment",
      "CursorLine",
      "Visual",
      "DiagnosticWarn",
      "TabLine",
      "Directory",
      "StatusLine",
      "Statement",
      "Normal",
    }
    local saved

    ---@param name string
    ---@return vim.api.keyset.get_hl_info
    local function group(name)
      return vim.api.nvim_get_hl(0, { name = name, link = false })
    end

    before_each(function()
      saved = {}
      for _, name in ipairs(GROUP_NAMES) do
        saved[name] = group(name)
      end
      -- `band_hl` is file-local with `band_icon` as its only writer, so without a pin
      -- here each test inherits whichever group the last one happened to set. No getter
      -- to read it back, so unlike the groups above it stays pinned past this block.
      vim.api.nvim_set_hl(0, "ChangesetSpecIcon", { fg = 0x00ff00 })
      render.band_icon("ChangesetSpecIcon")
    end)

    after_each(function()
      for _, name in ipairs(GROUP_NAMES) do
        vim.api.nvim_set_hl(0, name, saved[name])
      end
    end)

    it("keeps the previewed file's icon sitting on the band's new colour", function()
      vim.api.nvim_set_hl(0, "CursorLine", { bg = 0x123456 })

      render.define_highlights()

      local icon = group(render.PREVIEW_ICON_HL)
      assert.equal(0x123456, icon.bg)
      assert.equal(0x00ff00, icon.fg)
    end)

    it("makes the meta group Comment's colour with italics added", function()
      vim.api.nvim_set_hl(0, "Comment", { fg = 0x336699 })

      render.define_highlights()

      local meta = group(render.META_HL)
      assert.equal(0x336699, meta.fg)
      assert.is_true(meta.italic)
    end)

    it("falls back to Visual for the band in a theme that tints no CursorLine", function()
      vim.api.nvim_set_hl(0, "CursorLine", {})
      vim.api.nvim_set_hl(0, "Visual", { bg = 0xabcdef })

      render.define_highlights()

      assert.equal(0xabcdef, group(render.PREVIEW_HL).bg)
    end)

    it("paints the preview badge in the theme's warning colour", function()
      vim.api.nvim_set_hl(0, "Comment", { fg = 0x336699 })
      vim.api.nvim_set_hl(0, "DiagnosticWarn", { fg = 0xffaa00 })

      render.define_highlights()

      assert.equal(0xffaa00, group(render.PREVIEW_LABEL_HL).fg)
    end)

    it("falls back to Comment for the preview badge in a theme with no warning colour", function()
      vim.api.nvim_set_hl(0, "Comment", { fg = 0x336699 })
      vim.api.nvim_set_hl(0, "DiagnosticWarn", {})

      render.define_highlights()

      assert.equal(0x336699, group(render.PREVIEW_LABEL_HL).fg)
    end)

    it("paints the header with the theme's own chrome, not the band's shade", function()
      vim.api.nvim_set_hl(0, "CursorLine", { bg = 0x123456 })
      vim.api.nvim_set_hl(0, "TabLine", { bg = 0x654321 })

      render.define_highlights()

      assert.equal(0x654321, group(render.HEADER_HL).bg)
    end)

    it("falls back to the band for the header in a theme that paints no chrome", function()
      vim.api.nvim_set_hl(0, "CursorLine", { bg = 0x123456 })
      vim.api.nvim_set_hl(0, "TabLine", {})

      render.define_highlights()

      assert.equal(0x123456, group(render.HEADER_HL).bg)
    end)

    it("paints the footer badge in the theme's directory colour", function()
      vim.api.nvim_set_hl(0, "Comment", { fg = 0x336699 })
      vim.api.nvim_set_hl(0, "Directory", { fg = 0x4488cc })

      render.define_highlights()

      assert.equal(0x4488cc, group(render.BADGE_HL).fg)
    end)

    it("falls back to Comment for the footer badge in a theme with no directory colour", function()
      vim.api.nvim_set_hl(0, "Comment", { fg = 0x336699 })
      vim.api.nvim_set_hl(0, "Directory", {})

      render.define_highlights()

      assert.equal(0x336699, group(render.BADGE_HL).fg)
    end)

    it("reverses both badges, so neither needs an opaque Normal", function()
      render.define_highlights()

      assert.is_true(group(render.PREVIEW_LABEL_HL).reverse)
      assert.is_true(group(render.BADGE_HL).reverse)
    end)

    it("sets the header's icon, remote and ref on the header's strip", function()
      vim.api.nvim_set_hl(0, "TabLine", { bg = 0x654321 })
      vim.api.nvim_set_hl(0, "Directory", { fg = 0x4488cc })
      vim.api.nvim_set_hl(0, "Comment", { fg = 0x336699 })

      render.define_highlights()

      assert.same({ 0x4488cc, 0x654321 }, { group(render.HEADER_ICON_HL).fg, group(render.HEADER_ICON_HL).bg })
      assert.same({ 0x336699, 0x654321 }, { group(render.HEADER_DIM_HL).fg, group(render.HEADER_DIM_HL).bg })
      assert.equal(0x654321, group(render.HEADER_REF_HL).bg)
      assert.is_true(group(render.HEADER_REF_HL).bold)
    end)

    it("paints the footer on the statusline's own background", function()
      vim.api.nvim_set_hl(0, "StatusLine", { fg = 0xeeeeee, bg = 0x222222 })
      vim.api.nvim_set_hl(0, "Comment", { fg = 0x336699 })

      render.define_highlights()

      assert.same({ 0x336699, 0x222222 }, { group(render.FOOTER_HL).fg, group(render.FOOTER_HL).bg })
      assert.same({ 0xeeeeee, 0x222222 }, { group(render.FOOTER_KEY_HL).fg, group(render.FOOTER_KEY_HL).bg })
    end)

    ---@param color integer
    ---@return integer[] rgb
    local function channels(color)
      return { bit.band(bit.rshift(color, 16), 0xff), bit.band(bit.rshift(color, 8), 0xff), bit.band(color, 0xff) }
    end

    -- A red-only accent over a grey background: a tint of it moves the red channel alone.
    local BACKGROUND, RED = 0x101010, 0xf01010

    it("tints the selected row part of the way from the background to the theme's accent", function()
      vim.api.nvim_set_hl(0, "Normal", { fg = 0xcccccc, bg = BACKGROUND })
      vim.api.nvim_set_hl(0, "Statement", { fg = RED })

      render.define_highlights()

      local r, g, b = unpack(channels(group(render.SELECTED_HL).bg))
      assert.is_true(r > 0x10 and r < 0xf0)
      assert.same({ 0x10, 0x10 }, { g, b })
    end)

    it("tints the row you are on more faintly than the selected one", function()
      vim.api.nvim_set_hl(0, "Normal", { fg = 0xcccccc, bg = BACKGROUND })
      vim.api.nvim_set_hl(0, "Statement", { fg = RED })

      render.define_highlights()

      local here, selected = channels(group(render.HERE_HL).bg), channels(group(render.SELECTED_HL).bg)
      assert.is_true(here[1] > 0x10 and here[1] < selected[1])
      assert.same({ 0x10, 0x10 }, { here[2], here[3] })
    end)

    it("tints the row you last opened more faintly than the row you are on", function()
      vim.api.nvim_set_hl(0, "Normal", { fg = 0xcccccc, bg = BACKGROUND })
      vim.api.nvim_set_hl(0, "Statement", { fg = RED })

      render.define_highlights()

      local picked, here = channels(group(render.PICKED_HL).bg), channels(group(render.HERE_HL).bg)
      assert.is_true(picked[1] > 0x10 and picked[1] < here[1])
      assert.same({ 0x10, 0x10 }, { picked[2], picked[3] })
    end)

    it("tints over the theme's chrome when Normal is transparent", function()
      vim.api.nvim_set_hl(0, "Statement", { fg = RED })
      vim.api.nvim_set_hl(0, "Normal", { fg = 0xcccccc, bg = BACKGROUND })
      render.define_highlights()
      local opaque = group(render.SELECTED_HL).bg
      vim.api.nvim_set_hl(0, "Normal", { fg = 0xcccccc })
      vim.api.nvim_set_hl(0, "TabLine", { bg = BACKGROUND })

      render.define_highlights()

      assert.equal(opaque, group(render.SELECTED_HL).bg)
    end)

    it("tints toward Normal's text in a theme whose Statement has no colour", function()
      vim.api.nvim_set_hl(0, "Normal", { fg = RED, bg = BACKGROUND })
      vim.api.nvim_set_hl(0, "Statement", { bold = true })

      render.define_highlights()

      local r, g, b = unpack(channels(group(render.SELECTED_HL).bg))
      assert.is_true(r > 0x10 and r < 0xf0)
      assert.same({ 0x10, 0x10 }, { g, b })
    end)

    it("draws every state glyph in the accent", function()
      vim.api.nvim_set_hl(0, "Statement", { fg = 0xc8a0f0 })

      render.define_highlights()

      assert.same(
        { 0xc8a0f0, 0xc8a0f0, 0xc8a0f0 },
        { group(render.SELECTED_ICON_HL).fg, group(render.HERE_ICON_HL).fg, group(render.PICKED_ICON_HL).fg }
      )
    end)

    it("strikes a hidden kind through as well as dimming it", function()
      vim.api.nvim_set_hl(0, "Comment", { fg = 0x336699 })

      render.define_highlights()

      local hidden = group(render.HIDDEN_HL)
      assert.equal(0x336699, hidden.fg)
      assert.is_true(hidden.strikethrough)
    end)
  end)
  describe("kind_lines", function()
    local menu_opts = {
      icon = function()
        return "K", "Special"
      end,
      width = 24,
    }

    it("rails a kind that is showing and leaves the rail off one that is not", function()
      local lines = render.kind_lines({
        { kind = "Method", count = 11, hidden = false },
        { kind = "Variable", count = 31, hidden = true },
      }, menu_opts)

      assert.equal("▎ K Method", lines[1].text:gsub("%s+%d+$", ""))
      assert.equal("  K Variable", lines[2].text:gsub("%s+%d+$", ""))
    end)

    it("puts each count against the right edge", function()
      local lines = render.kind_lines({ { kind = "Method", count = 11, hidden = false } }, menu_opts)

      assert.equal(24, vim.fn.strdisplaywidth(lines[1].text))
      assert.truthy(lines[1].text:find("11$"))
    end)

    it("strikes through a hidden kind, so it reads as switched off", function()
      local lines = render.kind_lines({ { kind = "Variable", count = 31, hidden = true } }, menu_opts)

      local groups = vim.tbl_map(function(mark)
        return mark.hl
      end, lines[1].marks)
      assert.truthy(vim.tbl_contains(groups, render.HIDDEN_HL))
    end)

    it("colours a showing kind's name with the theme rather than the hidden group", function()
      local lines = render.kind_lines({ { kind = "Method", count = 11, hidden = false } }, menu_opts)

      local groups = vim.tbl_map(function(mark)
        return mark.hl
      end, lines[1].marks)
      assert.is_false(vim.tbl_contains(groups, render.HIDDEN_HL))
    end)

    it("carries each kind back on its line, so a cursor line names one", function()
      local lines = render.kind_lines({ { kind = "Method", count = 11, hidden = false } }, menu_opts)

      assert.equal("Method", lines[1].kind)
    end)
  end)

  describe("kind_list", function()
    it("joins two kinds with and", function()
      assert.equal("fields and variables", render.kind_list({ "Field", "Variable" }))
    end)

    it("pluralises a kind that does not just take an s", function()
      assert.equal("classes", render.kind_list({ "Class" }))
    end)

    it("splits a two-word kind into words", function()
      assert.equal("enum members", render.kind_list({ "EnumMember" }))
    end)
  end)

  describe("hidden_note", function()
    it("says nothing when every kind is showing", function()
      assert.is_nil(render.hidden_note({}, 44, "F"))
    end)

    it("names the one kind it is hiding", function()
      assert.equal("Hiding variables. F to change.", render.hidden_note({ "Variable" }, 44, "F"))
    end)

    it("counts the kinds instead once naming them would not fit", function()
      local note = render.hidden_note({ "Constructor", "Interface", "Property", "Variable" }, 44, "F")

      assert.equal("Hiding 4 kinds of symbol. F to change.", note)
    end)

    for _, kinds in ipairs({ { "Variable" }, { "Constructor", "Interface", "Property", "Variable" } }) do
      it(("names the key bound to the kind menu when hiding %d kind(s)"):format(#kinds), function()
        assert.truthy(assert(render.hidden_note(kinds, 44, "<C-k>")):find("<C-k>", 1, true))
      end)
    end

    it("ends at the kinds when the kind menu has no key", function()
      assert.truthy(vim.endswith(assert(render.hidden_note({ "Variable" }, 44, false)), "variables."))
    end)
  end)
end)
