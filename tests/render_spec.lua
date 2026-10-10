local highlights = require("changeset.highlights")
local render = require("changeset.render")
local present = require("support.present")

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
    read = "done",
    children = {},
  }, overrides or {}) --[[@as changeset.Row]]
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
  }, overrides or {}) --[[@as changeset.Row]]
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
  }, overrides or {}) --[[@as changeset.Row]]
end

---@param overrides? table
---@return changeset.RenderOpts
local function opts(overrides)
  return vim.tbl_extend("force", {
    icon = function(row)
      return row.kind == "file" and "F" or "S", "IconHl"
    end,
    collapsed = function()
      return false
    end,
    width = 80,
  }, overrides or {}) --[[@as changeset.RenderOpts]]
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
      local one = present(render.lines({ section() }, opts())[1])
      local two = present(render.lines({ section({ files = 2 }) }, opts())[1])

      assert.truthy((one.text:find("Implementation", 1, true)))
      assert.truthy((one.text:find("1 file$")))
      assert.truthy((two.text:find("2 files$")))
    end)

    it("leaves the cell before its icon blank, as the header strip does", function()
      local line = present(render.lines({ section() }, opts())[1])

      assert.equal(" S", line.text:sub(1, 2))
    end)

    it("starts every header's count in the same column", function()
      local lines = render.lines({ section(), section({ id = "#docs", name = "Docs" }) }, opts())

      assert.equal(present(lines[1]).text:find("1 file"), (present(lines[3]).text:find("1 file")))
    end)

    it("shrinks the label's padding so a wide stat clears the count", function()
      local wide = section({ files = 123, added = 15234, removed = 8123 })
      local narrow = present(render.lines({ wide }, opts({ width = 42 }))[1])

      assert.is_true(vim.fn.strdisplaywidth(narrow.text) + #"+15234 -8123" + 1 <= 42)
    end)

    it("draws the label as plain content", function()
      local line = present(render.lines({ section() }, opts())[1])

      for _, mark in ipairs(line.marks) do
        assert.is_false(mark.end_col ~= nil and line.text:sub(mark.col + 1, mark.end_col):find("Implementation") ~= nil)
      end
    end)

    it("draws the file count in the meta group", function()
      local line = present(render.lines({ section({ files = 2 }) }, opts())[1])

      assert.equal(highlights.META_HL, present(mark_over(line, "2 files")).hl)
    end)

    it("draws the header's icon in the group the caller gives it", function()
      local line = present(render.lines({ section() }, opts())[1])

      assert.equal("IconHl", present(mark_over(line, "S")).hl)
    end)

    it("right-aligns the section's stat", function()
      local mark = present(stat_mark(present(render.lines({ section() }, opts())[1])))

      assert.equal("right_align", mark.pos)
      assert.equal("+12", present(present(mark.virt_text)[1])[1])
    end)

    it("draws no rail on a section header", function()
      local line = present(render.lines({ section() }, opts())[1])

      assert.is_nil((line.text:find("▎", 1, true)))
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
      local line = present(render.lines({ section() }, opts({ query = "impl" }))[1])

      assert.is_nil(mark_over(line, "Impl"))
    end)
  end)

  describe("the Comments section", function()
    ---@param review_comment changeset.ReviewComment
    ---@return changeset.Row
    local function comment_row(review_comment)
      local path = review_comment.path
      return {
        id = "#comments\0" .. path,
        kind = "comment",
        depth = 1,
        name = path,
        path = path,
        lnum = review_comment.line,
        ancestor = false,
        children = {},
        review_comment = review_comment,
      }
    end

    ---@param fields table?
    ---@return changeset.Row
    local function saved(fields)
      return comment_row(
        vim.tbl_extend("force", { path = "src/a.lua", line = 42, body = "note\nmore" }, fields or {}) --[[@as changeset.ReviewComment]]
      )
    end

    ---@param children changeset.Row[]
    ---@return changeset.Row
    local function comments(children)
      return {
        id = "#comments",
        kind = "section",
        depth = 0,
        name = "Comments",
        path = "",
        comments = #children,
        ancestor = false,
        children = children,
      }
    end

    it("counts what it lists on its header, with no stat", function()
      local one = present(render.lines({ comments({ saved() }) }, opts())[1])
      local two = present(render.lines({ comments({ saved(), saved({ line = 43 }) }) }, opts())[1])

      assert.truthy((one.text:find("Comments", 1, true)))
      assert.truthy((one.text:find("1 comment$")))
      assert.truthy((two.text:find("2 comments$")))
      assert.is_nil(stat_mark(one))
    end)

    it("ends its header's count where a stat would end", function()
      local header = present(render.lines({ comments({ saved() }) }, opts({ width = 50 }))[1])

      assert.equal(50 - 2, vim.fn.strdisplaywidth(header.text))
    end)

    it("counts the drafts it lists on its header", function()
      local header = comments({ saved(), saved({ line = 43, draft = true }) })
      header.drafts = 1

      assert.truthy((present(render.lines({ header }, opts())[1]).text:find("2 comments · 1 draft$")))
    end)

    it("leads a draft's row with a dotted circle in the draft group", function()
      local line = present(render.lines({ comments({ saved({ draft = true }) }) }, opts())[2])

      assert.equal(" ◌ ", line.text:sub(1, #" ◌ "))
      assert.equal(highlights.REVIEW_COMMENT_DRAFT_HL, present(mark_over(line, "◌")).hl)
    end)

    it("leads a review comment's row with a solid circle in its group", function()
      local line = present(render.lines({ comments({ saved() }) }, opts())[2])

      assert.equal(" ● ", line.text:sub(1, #" ● "))
      assert.equal(highlights.REVIEW_COMMENT_HL, present(mark_over(line, "●")).hl)
    end)

    it("names the file and the line or range, then the body's first line, quiet", function()
      local one = present(render.lines({ comments({ saved() }) }, opts())[2])
      local range = present(render.lines({ comments({ saved({ start_line = 40 }) }) }, opts())[2])

      assert.truthy((one.text:find("a.lua:42%s%s+note$")))
      assert.truthy((range.text:find("a.lua:40%-42%s%s+note$")))
      assert.equal(highlights.REVIEW_COMMENT_BODY_HL, present(mark_over(one, "note")).hl)
    end)

    it("ends the body where a stat would end", function()
      local line = present(render.lines({ comments({ saved() }) }, opts({ width = 50 }))[2])

      assert.equal(50 - 2, vim.fn.strdisplaywidth(line.text))
    end)

    it("clips the body to the width", function()
      local line = present(render.lines({ comments({ saved({ body = ("word "):rep(40) }) }) }, opts({ width = 40 }))[2])

      assert.is_true(vim.fn.strdisplaywidth(line.text) <= 40 - 2)
      assert.truthy((line.text:find("…$")))
    end)

    it("clips a body of wide characters to the width", function()
      local line =
        present(render.lines({ comments({ saved({ body = ("日本語"):rep(10) }) }) }, opts({ width = 30 }))[2])

      assert.is_true(vim.fn.strdisplaywidth(line.text) <= 30 - 2, line.text)
    end)

    for _, width in ipairs({ 44, 30 }) do
      it(("fits a range on a long file name to width %d"):format(width), function()
        local long = saved({ path = "lua/changeset/review_comment_window.lua", line = 120, start_line = 112 })
        local line = present(render.lines({ comments({ long }) }, opts({ width = width }))[2])

        assert.is_true(vim.fn.strdisplaywidth(line.text) <= width - 2, line.text)
        assert.truthy((line.text:find("review_comment_", 1, true)))
      end)
    end
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

          assert.equal(" ▎", present(lines[1]).text:sub(1, #" ▎"))
          assert.same({ col = 1, end_col = 1 + #"▎", hl = hl }, mark_over(present(lines[1]), "▎"))
        end)
      end

      it("puts the icon, coloured by the caller's group, between the rail and the filename", function()
        local lines = file_lines({ file() }, opts())

        assert.equal(" ▎ F a.lua (src)", present(lines[1]).text)
        assert.equal("IconHl", present(mark_over(present(lines[1]), "F")).hl)
      end)

      it("dims the directory after the filename", function()
        local lines = file_lines({ file() }, opts())

        local mark = present(mark_over(present(lines[1]), "(src)"))
        assert.equal("Comment", mark.hl)
        assert.is_nil(mark.priority)
      end)

      it("draws a file at the repository root with no directory", function()
        local lines = file_lines({ file({ path = "a.lua" }) }, opts())

        assert.equal(" ▎ F a.lua", present(lines[1]).text)
      end)

      for _, status in ipairs({ "deleted", "renamed" }) do
        it(("ends a file with status '%s' with a Comment marker"):format(status), function()
          local lines = file_lines({ file({ status = status }) }, opts())

          assert.equal(" ▎ F a.lua (src) " .. status, present(lines[1]).text)
          assert.equal("Comment", present(mark_over(present(lines[1]), " " .. status)).hl)
        end)
      end

      for _, status in ipairs({ "added", "modified", "untracked" }) do
        it(("adds no marker for status '%s'"):format(status), function()
          local lines = file_lines({ file({ status = status }) }, opts())

          assert.equal(" ▎ F a.lua (src)", present(lines[1]).text)
        end)
      end
    end)

    describe("symbol rows", function()
      it("hangs a connector off each sibling, closing the last", function()
        local rows = {
          file({ children = { symbol({ name = "Alpha" }), symbol({ name = "Beta" }) } }),
        }

        assert.same({ " ▎ F a.lua (src)", "   ├─S Alpha", "   └─S Beta" }, texts(file_lines(rows, opts())))
      end)

      it("draws a name holding a line break on one line, its stat at the line's end", function()
        local lines = file_lines({ file({ children = { symbol({ name = "one\ntwo" }) } }) }, opts())

        assert.equal("   └─S one two", present(lines[2]).text)
        assert.equal(#present(lines[2]).text, present(stat_mark(present(lines[2]))).col)
      end)

      it("draws a path holding a line break on one line", function()
        local lines = file_lines({ file({ path = "new\r\nline.lua" }) }, opts())

        assert.equal(" ▎ F new  line.lua", present(lines[1]).text)
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
          " ▎ F a.lua (src)",
          "   ├─S First",
          "   │ └─S Inner",
          "   └─S Last",
          "     └─S Tail",
        }, texts(file_lines(rows, opts())))
      end)

      it("draws the connectors in Comment", function()
        local lines = file_lines({ file({ children = { symbol() } }) }, opts())

        assert.equal("Comment", present(mark_over(present(lines[2]), "└─")).hl)
      end)

      it("colours the kind icon with the caller's group", function()
        local lines = file_lines({ file({ children = { symbol() } }) }, opts())

        assert.equal("IconHl", present(mark_over(present(lines[2]), "S")).hl)
      end)

      it("draws an ancestor's name in Comment but keeps its icon colour", function()
        local ancestor = symbol({ name = "Container", ancestor = true })
        local lines = file_lines({ file({ children = { ancestor } }) }, opts())

        assert.equal("Comment", present(mark_over(present(lines[2]), "Container")).hl)
        assert.equal("IconHl", present(mark_over(present(lines[2]), "S")).hl)
      end)
    end)

    describe("stats", function()
      ---The stat's alignment and its coloured runs, leaving out the blanks between them.
      ---@param line changeset.Line
      ---@return string, table[]
      local function stat_runs(line)
        local mark = present(stat_mark(line))
        return present(mark.pos),
          vim.tbl_filter(function(chunk)
            return chunk[2] ~= nil
          end, present(mark.virt_text))
      end

      it("right-aligns +N in GitSignsAdd and -N in GitSignsDelete on a file row", function()
        local lines = file_lines({ file({ added = 12, removed = 3 }) }, opts())
        local pos, runs = stat_runs(present(lines[1]))

        assert.equal("right_align", pos)
        assert.same({ { "+12", "GitSignsAdd" }, { "-3", "GitSignsDelete" } }, runs)
      end)

      it("right-aligns them on a symbol row too", function()
        local rows = { file({ children = { symbol({ added = 8, removed = 1 }) } }) }
        local lines = file_lines(rows, opts())
        local pos, runs = stat_runs(present(lines[2]))

        assert.equal("right_align", pos)
        assert.same({ { "+8", "GitSignsAdd" }, { "-1", "GitSignsDelete" } }, runs)
      end)

      for _, counts in ipairs({ { 2, 0, "+2", "-0" }, { 0, 5, "+0", "-5" } }) do
        local added, removed, plus, minus = unpack(counts)
        it(("shows %s %s rather than dropping the zero"):format(plus, minus), function()
          local lines = file_lines({ file({ added = added, removed = removed }) }, opts())
          local _, runs = stat_runs(present(lines[1]))

          assert.same({ { plus, "GitSignsAdd" }, { minus, "GitSignsDelete" } }, runs)
        end)
      end

      it("emits no stat for a row that carries none", function()
        local bare = symbol()
        bare.added, bare.removed = nil, nil
        local lines = file_lines({ file({ children = { bare } }) }, opts())

        assert.is_nil(stat_mark(present(lines[2])))
      end)

      it("emits no stat for an ancestor, even when numbers were left on it", function()
        local ancestor = symbol({ ancestor = true, added = 8, removed = 1 })
        local lines = file_lines({ file({ children = { ancestor } }) }, opts())

        assert.is_nil(stat_mark(present(lines[2])))
      end)
    end)

    describe("state_marks", function()
      ---@param state "selected"|"here"|"picked"
      ---@return vim.api.keyset.set_extmark tint, vim.api.keyset.set_extmark glyph
      local function marks(state)
        local tint ---@type vim.api.keyset.set_extmark?
        local glyph ---@type vim.api.keyset.set_extmark?
        for _, mark in ipairs(render.state_marks(state, 44)) do
          if mark.virt_text then
            glyph = mark
          else
            tint = mark
          end
        end
        return present(tint), present(glyph)
      end

      it("tints the selected row to the window's edge, its glyph in the last column", function()
        local tint, glyph = marks("selected")

        assert.same(
          { highlights.SELECTED_HL, true, render.SELECTED_ICON, 43 },
          { tint.hl_group, tint.hl_eol, present(glyph.virt_text)[1][1], glyph.virt_text_win_col }
        )
      end)

      it("marks the row you are on the same way, in its own tint and glyph", function()
        local tint, glyph = marks("here")

        assert.same(
          { highlights.HERE_HL, true, render.HERE_ICON, 43 },
          { tint.hl_group, tint.hl_eol, present(glyph.virt_text)[1][1], glyph.virt_text_win_col }
        )
      end)

      it("marks the row you last opened the same way, in its own tint and glyph", function()
        local tint, glyph = marks("picked")

        assert.same(
          { highlights.PICKED_HL, true, render.PICKED_ICON, 43 },
          { tint.hl_group, tint.hl_eol, present(glyph.virt_text)[1][1], glyph.virt_text_win_col }
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
        local stat = present(present(stat_mark(present(lines[1]))).virt_text)
        local tail = stat[#stat][1]
        local _, glyph = marks("selected")

        assert.equal("", vim.trim(tail))
        assert.is_true(glyph.virt_text_win_col > 44 - #tail and glyph.virt_text_win_col < 44)
      end)
    end)

    describe("symbols still resolving", function()
      it("adds a placeholder child under a file whose children have not arrived", function()
        local lines = file_lines({ file({ read = "reading" }) }, opts())

        assert.same({ " ▎ F a.lua (src)", "   └─⋯ reading symbols" }, texts(lines))
        assert.equal(highlights.META_HL, present(mark_over(present(lines[2]), "⋯ reading symbols")).hl)
      end)

      it("shows only the file row once a file is read but nothing inside it changed", function()
        local lines = file_lines({ file({ read = "done" }) }, opts())

        assert.same({ " ▎ F a.lua (src)" }, texts(lines))
      end)

      it("nests the placeholder under the file as a row of its own", function()
        local lines = file_lines({ file({ read = "reading" }) }, opts())

        assert.not_equal(present(present(lines[1]).row).id, present(present(lines[2]).row).id)
        assert.equal(present(present(lines[1]).row).depth + 1, present(present(lines[2]).row).depth)
        assert.equal("src/a.lua", present(present(lines[2]).row).path)
      end)

      it("shows no placeholder for a deleted file, whose subtree is empty by design", function()
        local lines = file_lines({ file({ status = "deleted" }) }, opts())

        assert.same({ " ▎ F a.lua (src) deleted" }, texts(lines))
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

        assert.equal(highlights.META_HL, present(mark_over(present(lines[2]), "Other changes")).hl)
        assert.equal(highlights.META_HL, present(mark_over(present(lines[3]), "L4–6 local x = 1")).hl)
      end)

      it("dims their icon instead of using the caller's colour", function()
        local lines = file_lines(with_orphans(), opts())

        assert.equal(highlights.META_HL, present(mark_over(present(lines[2]), "S")).hl)
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

        assert.same({ " ▎ F a.lua (src)" }, texts(lines))
      end)

      it("hides the placeholder of a collapsed file still resolving", function()
        local lines = file_lines({ file({ read = "reading" }) }, opts({ collapsed = collapsed_ids("src/a.lua") }))

        assert.same({ " ▎ F a.lua (src)" }, texts(lines))
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
          return present(line.row).id
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

        assert.same({ " ▎ F a.lua (src)", "   ├─S Outer", "   └─S Next" }, texts(lines))
      end)
    end)

    describe("fitting to the window width", function()
      it("trims a long symbol chain from the left so its stat stays on screen", function()
        local chain = symbol({ name = "SessionStore › refresh › deadline", added = 8, removed = 1 })
        local lines = file_lines({ file({ children = { chain } }) }, opts({ width = 31 }))

        assert.equal("   └─S … › deadline", present(lines[2]).text)
        assert.not_nil(stat_mark(present(lines[2])))
      end)

      it("trims a long directory from the left, keeping the whole filename and the marker", function()
        local deleted = file({ status = "deleted", path = "very/long/dir/structure/deleted_file.lua" })
        deleted.added, deleted.removed = nil, nil
        local lines = file_lines({ deleted }, opts({ width = 47 }))

        assert.equal(" ▎ F deleted_file.lua (…/structure) deleted", present(lines[1]).text)
      end)

      it("drops the directory when the filename leaves no room for it", function()
        local deleted = file({ status = "deleted", path = "very/long/dir/structure/deleted_file.lua" })
        deleted.added, deleted.removed = nil, nil
        local lines = file_lines({ deleted }, opts({ width = 31 }))

        assert.equal(" ▎ F deleted_file.lua deleted", present(lines[1]).text)
      end)

      it("trims an orphan hunk of wide characters short of its stat", function()
        local hunk = symbol({ kind = "orphan", name = ("日本語"):rep(10) })
        local lines = file_lines({ file({ children = { hunk } }) }, opts({ width = 31 }))

        local room = 31 - (vim.fn.strdisplaywidth("+8 -1") + 3)
        assert.is_true(vim.fn.strdisplaywidth(present(lines[2]).text) <= room, present(lines[2]).text)
      end)

      it("trims a symbol name of wide characters short of its stat", function()
        local lines =
          file_lines({ file({ children = { symbol({ name = ("名前"):rep(15) }) } }) }, opts({ width = 31 }))

        local room = 31 - (vim.fn.strdisplaywidth("+8 -1") + 3)
        assert.is_true(vim.fn.strdisplaywidth(present(lines[2]).text) <= room, present(lines[2]).text)
      end)

      it("trims an orphan hunk from the right, keeping its line range", function()
        local hunk = symbol({ kind = "orphan", name = "L4–6 local x = 1 + something long" })
        hunk.added, hunk.removed = nil, nil
        local lines = file_lines({ file({ children = { hunk } }) }, opts({ width = 31 }))

        assert.equal("   └─S L4–6 local x = 1 + so…", present(lines[2]).text)
      end)
    end)
  end)

  describe("filter highlighting", function()
    it("marks the characters a filter query matched", function()
      local lines = file_lines({ file() }, opts({ query = "a.lua" }))

      local mark = present(mark_over(present(lines[1]), "a.lua"))

      assert.equal(highlights.MATCH_HL, mark.hl)
    end)

    -- An ancestor row, which is the case with a colour of its own to sit under:
    -- it is dimmed to `Comment`, and a match on it still has to read.
    it("draws the match over the colour the row already carries", function()
      local rows = { file({ children = { symbol({ name = "Alpha", ancestor = true }) } }) }

      local lines = file_lines(rows, opts({ query = "lph" }))

      local match = present(mark_over(present(lines[2]), "lph"))
      local name = present(mark_over(present(lines[2]), "Alpha"))

      assert.is_nil(name.priority)
      assert.is_true(match.priority > render.MARK_PRIORITY)
    end)

    it("takes the query as plain text, not as a pattern", function()
      local lines = file_lines({ file({ path = "a(b).lua" }) }, opts({ query = "(" }))

      local mark = present(mark_over(present(lines[1]), "("))

      assert.equal(highlights.MATCH_HL, mark.hl)
    end)

    it("leaves the rows unmarked when nothing is being filtered", function()
      local lines = file_lines({ file() }, opts())

      for _, mark in ipairs(present(lines[1]).marks) do
        assert.not_equal(highlights.MATCH_HL, mark.hl)
      end
    end)
  end)

  describe("header", function()
    local LONG = "origin/jt/exc-1200-stacked-parent-branch-with-a-long-name"

    ---@param summary table
    ---@param width integer?
    ---@param with_highlights boolean?
    ---@return { str: string, highlights: table[]? }
    local function eval(summary, width, with_highlights)
      width = width or 44
      return vim.api.nvim_eval_statusline(
        render.header(summary, width),
        { use_winbar = true, maxwidth = width, highlights = with_highlights }
      )
    end

    ---The group drawing the first byte of `needle` in an evaluated statusline.
    ---@param shown { str: string, highlights: table[]? }
    ---@param needle string
    ---@return string?
    local function group_at(shown, needle)
      local at = present((shown.str:find(needle, 1, true))) - 1
      local found
      for _, mark in ipairs(present(shown.highlights)) do
        if mark.start <= at then
          found = mark.group
        end
      end
      return found
    end

    it("names what the tree is compared against", function()
      assert.truthy((eval({ ref = "origin/trunk" }).str:find("origin/trunk", 1, true)))
    end)

    it("keeps the head of a ref too long to fit, marking the cut at its end", function()
      local text = eval({ ref = LONG }, 30).str

      assert.truthy((text:find("origin/jt/exc-1200", 1, true)))
      assert.truthy(vim.endswith(vim.trim(text), "…"))
      -- The statusline marks a cut of its own with `<`, and keeps the tail.
      assert.falsy((text:find("<", 1, true)))
    end)

    it("names the branch's open PR at the right edge, a blank cell clear of it", function()
      assert.equal(" #412 ", eval({ ref = "origin/trunk", pr = 412 }).str:sub(-6))
    end)

    it("gives up the ref's tail rather than the PR number", function()
      local text = eval({ ref = LONG, pr = 412 }, 30).str

      assert.equal(" #412 ", text:sub(-6))
      assert.truthy((text:find("origin/jt", 1, true)))
      assert.truthy((text:find("…", 1, true)))
      assert.falsy((text:find("<", 1, true)))
    end)

    it("escapes % in the ref so the statusline does not read it as an item", function()
      assert.truthy((eval({ ref = "origin/50%off" }).str:find("origin/50%off", 1, true)))
    end)

    it("dims the remote so the branch name leads", function()
      highlights.define_highlights()
      local shown = eval({ ref = "origin/trunk" }, 44, true)

      assert.equal(highlights.HEADER_DIM_HL, group_at(shown, "origin/"))
      assert.equal(highlights.HEADER_REF_HL, group_at(shown, "trunk"))
    end)

    it("reads a local ref whole, with nothing dimmed", function()
      highlights.define_highlights()
      local shown = eval({ ref = "jt/parent" }, 44, true)

      assert.equal(highlights.HEADER_REF_HL, group_at(shown, "jt/parent"))
    end)
  end)

  describe("header_totals", function()
    local BASE = { ref = "origin/trunk", files = 7, added = 142, removed = 38 }

    ---@param overrides table?
    ---@return table[] chunks
    local function totals(overrides)
      return render.header_totals(vim.tbl_extend("force", BASE, overrides or {}) --[[@as changeset.Summary]], 44)
    end

    ---@param chunks table[]
    ---@return string
    local function text(chunks)
      return table.concat(vim.tbl_map(function(chunk)
        return chunk[1]
      end, chunks))
    end

    it("counts the files, saying '1 file' for one", function()
      assert.truthy((text(totals()):find("7 files", 1, true)))
      assert.truthy((text(totals({ files = 1 })):find("1 file", 1, true)))
      assert.falsy((text(totals({ files = 1 })):find("1 files", 1, true)))
    end)

    it("counts the branch's commits, saying '1 commit' for one", function()
      assert.truthy((text(totals({ commits = 3 })):find("3 commits", 1, true)))
      assert.falsy((text(totals({ commits = 1 })):find("1 commits", 1, true)))
      assert.truthy((text(totals({ commits = 1 })):find("1 commit", 1, true)))
    end)

    it("sets the commits beside the line totals", function()
      assert.truthy((text(totals({ commits = 3 })):find("3 commits  +142 -38", 1, true)))
    end)

    it("leaves commits out when there are none to count", function()
      assert.falsy((text(totals()):find("commit", 1, true)))
      assert.falsy((text(totals({ commits = 0 })):find("commit", 1, true)))
    end)

    it("ends the line totals in the column the rows' stats end in, filling the width", function()
      local line = text(totals())
      local row = present(file_lines({ file({ added = 142, removed = 38 }) }, opts({ width = 44 }))[1])
      local stat = table.concat(vim.tbl_map(function(chunk)
        return chunk[1]
      end, present(present(stat_mark(row)).virt_text)))

      assert.truthy(vim.endswith(line, " " .. stat))
      assert.equal(44, vim.fn.strdisplaywidth(line))
    end)

    it("reports symbols being read in place of the counts on the left", function()
      local line = text(totals({ commits = 3, reading = { done = 12, total = 28 } }))

      assert.truthy((line:find("reading symbols 12/28", 1, true)))
      assert.falsy((line:find("files", 1, true)))
      assert.falsy((line:find("commit", 1, true)))
      assert.truthy((line:find(" +142 -38", 1, true)))
    end)

    it("draws every chunk on the header's strip", function()
      vim.api.nvim_set_hl(0, "ChangesetSpecStrip", { bg = 0x654321 })
      local tabline = vim.api.nvim_get_hl(0, { name = "TabLine" })
      vim.api.nvim_set_hl(0, "TabLine", { link = "ChangesetSpecStrip" })
      highlights.define_highlights()

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

      assert.same({ highlights.HEADER_HL, "GitSignsAdd" }, by_text["+142"])
      assert.same({ highlights.HEADER_HL, "GitSignsDelete" }, by_text["-38"])
    end)
  end)

  describe("footer", function()
    ---@param info table
    ---@return string
    local function shown(info)
      local keys = { jump = "<CR>", filter = "f", filter_kinds = "F", help = "?" }
      local full =
        vim.tbl_extend("force", { files = 12, query = "", keys = keys, branch = "feature", ref = "origin/trunk" }, info) --[[@as changeset.Footer]]
      return vim.api.nvim_eval_statusline(render.footer(full), { maxwidth = 120 }).str
    end

    it("says which of the files shown the cursor is in", function()
      assert.truthy((shown({ file = 3 }):find("file 3 of 12", 1, true)))
    end)

    it("names the branch and the ref it is compared against, right after the badge", function()
      local footer = shown({ file = 3 })
      local branch_at = present((footer:find(" feature", 1, true)))
      local ref_at = present((footer:find(" origin/trunk", 1, true)))

      assert.truthy(footer:find("Changeset", 1, true) < branch_at)
      assert.truthy(branch_at < ref_at)
      assert.truthy((ref_at < footer:find("file 3 of 12", 1, true)))
    end)

    it("escapes % in the branch so the statusline does not read it as an item", function()
      assert.truthy((shown({ branch = "50%-off" }):find("50%-off", 1, true)))
    end)

    it("leaves the position out when the cursor is in no file", function()
      assert.falsy((shown({}):find(" of 12", 1, true)))
    end)

    it("shows the filter in force", function()
      assert.truthy((shown({ query = "sess" }):find("sess", 1, true)))
    end)

    it("escapes % in the filter so the statusline does not read it as an item", function()
      assert.truthy((shown({ query = "50%" }):find("50%", 1, true)))
    end)

    it("points at ? for every key, at the right edge", function()
      assert.truthy(vim.endswith(shown({}), "? all keys "))
    end)

    it("names a remapped key, escaping %", function()
      local footer = shown({ keys = { jump = "o%", filter = "f", filter_kinds = "F", help = "?" } })

      assert.truthy((footer:find("o% open", 1, true)))
      assert.falsy((footer:find("<CR>", 1, true)))
    end)

    it("leaves out a key set to false", function()
      local footer = shown({ keys = { jump = "<CR>", filter = false, filter_kinds = "F", help = "?" } })

      assert.falsy((footer:find("filter", 1, true)))
      assert.truthy((footer:find("F kinds", 1, true)))
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
        icon_hl = highlights.PREVIEW_ICON_HL,
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

      assert.is_nil((shown:find("to open", 1, true)))
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
      highlights.define_highlights()
      highlights.band_icon("Comment")
      local shown = vim.api.nvim_eval_statusline(
        render.preview_winbar(band()),
        { use_winbar = true, maxwidth = 60, highlights = true }
      )

      assert.same(
        { highlights.PREVIEW_LABEL_HL, highlights.PREVIEW_ICON_HL, highlights.PREVIEW_HL, highlights.PREVIEW_HINT_HL },
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

  describe("compose", function()
    it("joins the chunks, marking each coloured one's byte range with its group or groups", function()
      local line = render.compose(nil, { { "é " }, { "Yes", { "A", "B" } }, { "!", "C" } })

      assert.equal("é Yes!", line.text)
      assert.same({ { col = 3, end_col = 6, hl = { "A", "B" } }, { col = 6, end_col = 7, hl = "C" } }, line.marks)
    end)
  end)

  describe("empty_message", function()
    it("names the default branch, then the remote it matches", function()
      local message = render.empty_message({ on_default_branch = true, branch = "trunk", ref = "origin/trunk" })
      local branch_at, ref_at = message:find("trunk", 1, true), message:find("origin/trunk", 1, true)

      assert.truthy(branch_at and ref_at and branch_at < ref_at)
    end)

    it("names the default branch once when it has no remote to compare against", function()
      local message = render.empty_message({ on_default_branch = true, branch = "trunk", ref = "trunk" })

      assert.equal(1, select(2, message:gsub("trunk", "")))
    end)

    it("names a branch with no diff, then the ref it matches", function()
      local message = render.empty_message({ on_default_branch = false, branch = "feat/x", ref = "origin/develop" })
      local branch_at, ref_at = message:find("feat/x", 1, true), message:find("origin/develop", 1, true)

      assert.truthy(branch_at and ref_at and branch_at < ref_at)
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

      assert.equal("▎ K Method", (present(lines[1]).text:gsub("%s+%d+$", "")))
      assert.equal("  K Variable", (present(lines[2]).text:gsub("%s+%d+$", "")))
    end)

    it("puts each count against the right edge", function()
      local lines = render.kind_lines({ { kind = "Method", count = 11, hidden = false } }, menu_opts)

      assert.equal(24, vim.fn.strdisplaywidth(present(lines[1]).text))
      assert.truthy((present(lines[1]).text:find("11$")))
    end)

    it("strikes through a hidden kind, so it reads as switched off", function()
      local lines = render.kind_lines({ { kind = "Variable", count = 31, hidden = true } }, menu_opts)

      local groups = vim.tbl_map(function(mark)
        return mark.hl
      end, present(lines[1]).marks)
      assert.truthy(vim.tbl_contains(groups, highlights.HIDDEN_HL))
    end)

    it("colours a showing kind's name with the theme rather than the hidden group", function()
      local lines = render.kind_lines({ { kind = "Method", count = 11, hidden = false } }, menu_opts)

      local groups = vim.tbl_map(function(mark)
        return mark.hl
      end, present(lines[1]).marks)
      assert.is_false(vim.tbl_contains(groups, highlights.HIDDEN_HL))
    end)

    it("carries each kind back on its line, so a cursor line names one", function()
      local lines = render.kind_lines({ { kind = "Method", count = 11, hidden = false } }, menu_opts)

      assert.equal("Method", present(lines[1]).kind)
    end)
  end)

  describe("kind_list", function()
    it("joins two kinds with and", function()
      assert.equal("fields and variables", render.kind_list({ "Field", "Variable" }))
    end)

    it("joins three kinds with commas and a final and", function()
      assert.equal("fields, methods and variables", render.kind_list({ "Field", "Method", "Variable" }))
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
      assert.truthy((present(render.hidden_note({ "Variable" }, 44, "F")):find("variables", 1, true)))
    end)

    it("counts the kinds instead once naming them would not fit", function()
      local note = present(render.hidden_note({ "Constructor", "Interface", "Property", "Variable" }, 44, "F"))

      assert.truthy((note:find("4", 1, true)))
      for _, name in ipairs({ "constructors", "interfaces", "properties", "variables" }) do
        assert.is_nil((note:find(name, 1, true)))
      end
    end)

    for _, kinds in ipairs({ { "Variable" }, { "Constructor", "Interface", "Property", "Variable" } }) do
      it(("names the key bound to the kind menu when hiding %d kind(s)"):format(#kinds), function()
        assert.truthy((present(render.hidden_note(kinds, 44, "<C-k>")):find("<C-k>", 1, true)))
      end)
    end

    it("ends at the kinds when the kind menu has no key", function()
      assert.truthy(vim.endswith(present(render.hidden_note({ "Variable" }, 44, false)), "variables."))
    end)
  end)
end)
