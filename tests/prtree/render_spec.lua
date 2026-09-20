local render = require("plugins.prtree.render")

---@param overrides? table
---@return prtree.Row
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
---@return prtree.Row
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
---@param line prtree.Line
---@param covered string
---@return prtree.Mark?
local function mark_over(line, covered)
  for _, mark in ipairs(line.marks) do
    if mark.end_col and line.text:sub(mark.col + 1, mark.end_col) == covered then
      return mark
    end
  end
end

---@param lines prtree.Line[]
---@return string[]
local function texts(lines)
  return vim.tbl_map(function(line)
    return line.text
  end, lines)
end

---The virtual-text mark of a line, if it has one.
---@param line prtree.Line
---@return prtree.Mark?
local function stat_mark(line)
  for _, mark in ipairs(line.marks) do
    if mark.virt_text then
      return mark
    end
  end
end

describe("prtree.render", function()
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
          local lines = render.lines({ file({ status = status }) }, opts())

          assert.equal("▎", lines[1].text:sub(1, #"▎"))
          assert.same({ col = 0, end_col = #"▎", hl = hl }, mark_over(lines[1], "▎"))
        end)
      end

      it("puts the icon, coloured by the caller's group, between the rail and the path", function()
        local lines = render.lines({ file() }, opts())

        assert.equal("▎ F src/a.lua", lines[1].text)
        assert.equal("IconHl", mark_over(lines[1], "F").hl)
      end)

      for _, status in ipairs({ "deleted", "renamed" }) do
        it(("ends a file with status '%s' with a Comment marker"):format(status), function()
          local lines = render.lines({ file({ status = status }) }, opts())

          assert.equal("▎ F src/a.lua " .. status, lines[1].text)
          assert.equal("Comment", mark_over(lines[1], " " .. status).hl)
        end)
      end

      for _, status in ipairs({ "added", "modified", "untracked" }) do
        it(("adds no text after the path for status '%s'"):format(status), function()
          local lines = render.lines({ file({ status = status }) }, opts())

          assert.equal("▎ F src/a.lua", lines[1].text)
        end)
      end
    end)

    describe("symbol rows", function()
      it("hangs a connector off each sibling, closing the last", function()
        local rows = {
          file({ children = { symbol({ name = "Alpha" }), symbol({ name = "Beta" }) } }),
        }

        assert.same({ "▎ F src/a.lua", "  ├─S Alpha", "  └─S Beta" }, texts(render.lines(rows, opts())))
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
          "▎ F src/a.lua",
          "  ├─S First",
          "  │ └─S Inner",
          "  └─S Last",
          "    └─S Tail",
        }, texts(render.lines(rows, opts())))
      end)

      it("draws the connectors in Comment", function()
        local lines = render.lines({ file({ children = { symbol() } }) }, opts())

        assert.equal("Comment", mark_over(lines[2], "└─").hl)
      end)

      it("colours the kind icon with the caller's group", function()
        local lines = render.lines({ file({ children = { symbol() } }) }, opts())

        assert.equal("IconHl", mark_over(lines[2], "S").hl)
      end)

      it("draws an ancestor's name in Comment but keeps its icon colour", function()
        local ancestor = symbol({ name = "Container", ancestor = true })
        local lines = render.lines({ file({ children = { ancestor } }) }, opts())

        assert.equal("Comment", mark_over(lines[2], "Container").hl)
        assert.equal("IconHl", mark_over(lines[2], "S").hl)
      end)
    end)

    describe("stats", function()
      local function right_aligned(line, added, removed)
        return {
          col = #line.text,
          pos = "right_align",
          virt_text = { { "+" .. added, "GitSignsAdd" }, { " " }, { "-" .. removed, "GitSignsDelete" } },
        }
      end

      it("right-aligns +N in GitSignsAdd and -N in GitSignsDelete on a file row", function()
        local lines = render.lines({ file({ added = 12, removed = 3 }) }, opts())

        assert.same(right_aligned(lines[1], 12, 3), stat_mark(lines[1]))
      end)

      it("right-aligns them on a symbol row too", function()
        local rows = { file({ children = { symbol({ added = 8, removed = 1 }) } }) }
        local lines = render.lines(rows, opts())

        assert.same(right_aligned(lines[2], 8, 1), stat_mark(lines[2]))
      end)

      for _, counts in ipairs({ { 2, 0 }, { 0, 5 } }) do
        local added, removed = counts[1], counts[2]
        it(("shows +%d -%d rather than dropping the zero"):format(added, removed), function()
          local lines = render.lines({ file({ added = added, removed = removed }) }, opts())

          assert.same(right_aligned(lines[1], added, removed), stat_mark(lines[1]))
        end)
      end

      it("emits no stat for a row that carries none", function()
        local bare = symbol()
        bare.added, bare.removed = nil, nil
        local lines = render.lines({ file({ children = { bare } }) }, opts())

        assert.is_nil(stat_mark(lines[2]))
      end)

      it("emits no stat for an ancestor, even when numbers were left on it", function()
        local ancestor = symbol({ ancestor = true, added = 8, removed = 1 })
        local lines = render.lines({ file({ children = { ancestor } }) }, opts())

        assert.is_nil(stat_mark(lines[2]))
      end)
    end)

    describe("symbols still resolving", function()
      it("adds a placeholder child under a file whose children have not arrived", function()
        local lines = render.lines({ file({ resolved = false }) }, opts())

        assert.same({ "▎ F src/a.lua", "  └─⋯ reading symbols" }, texts(lines))
        assert.equal(render.META_HL, mark_over(lines[2], "⋯ reading symbols").hl)
      end)

      it("shows only the file row once a file is resolved but nothing inside it changed", function()
        local lines = render.lines({ file({ resolved = true }) }, opts())

        assert.same({ "▎ F src/a.lua" }, texts(lines))
      end)

      it("ties the placeholder line to the file it stands in for", function()
        local lines = render.lines({ file({ resolved = false }) }, opts())

        assert.equal("src/a.lua", lines[2].row.id)
      end)

      it("shows no placeholder for a deleted file, whose subtree is empty by design", function()
        local lines = render.lines({ file({ status = "deleted" }) }, opts())

        assert.same({ "▎ F src/a.lua deleted" }, texts(lines))
      end)

      it("shows no placeholder once the file has children", function()
        local lines = render.lines({ file({ children = { symbol() } }) }, opts())

        assert.same({ "▎ F src/a.lua", "  └─S Foo" }, texts(lines))
      end)
    end)

    describe("orphan hunks", function()
      local function with_orphans()
        local hunk = symbol({ id = "src/a.lua\0#orphan:4", kind = "orphan", name = "L4–6 local x = 1" })
        local group =
          symbol({ id = "src/a.lua\0#orphans", kind = "orphans", name = "Other changes", children = { hunk } })
        return { file({ children = { group } }) }
      end

      it("draws the group and its hunks in the meta group", function()
        local lines = render.lines(with_orphans(), opts())

        assert.equal(render.META_HL, mark_over(lines[2], "Other changes").hl)
        assert.equal(render.META_HL, mark_over(lines[3], "L4–6 local x = 1").hl)
      end)

      it("dims their icon instead of using the caller's colour", function()
        local lines = render.lines(with_orphans(), opts())

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
        local lines = render.lines(rows, opts({ collapsed = collapsed_ids("src/a.lua") }))

        assert.same({ "▎ F src/a.lua" }, texts(lines))
      end)

      it("hides the placeholder of a collapsed file still resolving", function()
        local lines = render.lines({ file({ resolved = false }) }, opts({ collapsed = collapsed_ids("src/a.lua") }))

        assert.same({ "▎ F src/a.lua" }, texts(lines))
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
        local lines = render.lines(rows, opts({ collapsed = collapsed_ids("a.lua") }))

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
        local lines = render.lines(rows, opts({ collapsed = collapsed_ids("outer") }))

        assert.same({ "▎ F src/a.lua", "  ├─S Outer", "  └─S Next" }, texts(lines))
      end)
    end)

    describe("fitting to the window width", function()
      it("trims a long symbol chain from the left so its stat stays on screen", function()
        local chain = symbol({ name = "SessionStore › refresh › deadline", added = 8, removed = 1 })
        local lines = render.lines({ file({ children = { chain } }) }, opts({ width = 30 }))

        assert.equal("  └─S … › deadline", lines[2].text)
        assert.is_not_nil(stat_mark(lines[2]))
      end)

      it("trims a long path from the left, keeping the file name and the marker", function()
        local deleted = file({ status = "deleted", path = "very/long/dir/structure/deleted_file.lua" })
        deleted.added, deleted.removed = nil, nil
        local lines = render.lines({ deleted }, opts({ width = 30 }))

        assert.equal("▎ F …/deleted_file.lua deleted", lines[1].text)
      end)

      it("trims an orphan hunk from the right, keeping its line range", function()
        local hunk = symbol({ kind = "orphan", name = "L4–6 local x = 1 + something long" })
        hunk.added, hunk.removed = nil, nil
        local lines = render.lines({ file({ children = { hunk } }) }, opts({ width = 30 }))

        assert.equal("  └─S L4–6 local x = 1 + some…", lines[2].text)
      end)
    end)
  end)

  describe("winbar", function()
    it("states what the tree is compared against, then the file count and line totals", function()
      local summary = { base_ref = "origin/trunk", files = 7, added = 142, removed = 38 }

      assert.equal(" vs origin/trunk      7 files  +142 -38", render.winbar(summary))
    end)

    it("says '1 file', not '1 files'", function()
      local summary = { base_ref = "origin/trunk", files = 1, added = 3, removed = 0 }

      assert.equal(" vs origin/trunk      1 file  +3 -0", render.winbar(summary))
    end)

    it("escapes % in the base ref so the statusline does not read it as an item", function()
      local summary = { base_ref = "origin/50%off", files = 2, added = 1, removed = 1 }

      assert.equal(" vs origin/50%%off      2 files  +1 -1", render.winbar(summary))
    end)
  end)

  describe("preview_winbar", function()
    it("names the file being previewed", function()
      assert.is_true(render.preview_winbar("lua/init.lua"):find("lua/init.lua", 1, true) ~= nil)
    end)

    it("escapes % in the path so the statusline does not read it as an item", function()
      assert.is_true(render.preview_winbar("a/50%off.md"):find("50%%off", 1, true) ~= nil)
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
    local comment

    before_each(function()
      comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
    end)

    after_each(function()
      vim.api.nvim_set_hl(0, "Comment", comment)
    end)

    it("makes the meta group Comment's colour with italics added", function()
      vim.api.nvim_set_hl(0, "Comment", { fg = 0x336699 })

      render.define_highlights()

      local meta = vim.api.nvim_get_hl(0, { name = render.META_HL, link = false })
      assert.equal(0x336699, meta.fg)
      assert.is_true(meta.italic)
    end)
  end)
end)
