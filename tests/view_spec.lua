local Changes = require("support.changes")
local Rows = require("changeset.rows")
local view = require("changeset.view")

---@param id string
---@param name string
---@param children changeset.Row[]?
---@return changeset.Row
local function row(id, name, children)
  return { id = id, name = name, children = children or {} }
end

---Names of a row tree, depth-first, parents before children.
---@param rows changeset.Row[]
---@return string[]
local function names(rows)
  local out = {}
  local function walk(list)
    for _, r in ipairs(list) do
      out[#out + 1] = r.name
      walk(r.children or {})
    end
  end
  walk(rows)
  return out
end

---@param id string
---@param name string
---@param kind string LSP kind name.
---@param children changeset.Row[]?
---@return changeset.Row
local function sym(id, name, kind, children)
  return { id = id, kind = "symbol", name = name, symbol_kind = kind, children = children or {} }
end

describe("changeset.view", function()
  describe("filter", function()
    it("returns the whole tree for an empty query", function()
      local rows = { row("f1", "session.ts", { row("s1", "refresh") }) }

      assert.same({ "session.ts", "refresh" }, names(view.filter(rows, "")))
    end)

    it("keeps a matching row's ancestors so the match stays placed", function()
      local rows = {
        row("f1", "session.ts", { row("s1", "Store", { row("s2", "refresh") }) }),
        row("f2", "auth.ts", { row("s3", "verify") }),
      }

      assert.same({ "session.ts", "Store", "refresh" }, names(view.filter(rows, "refresh")))
    end)

    it("keeps a matching parent's children, so a matched file shows its symbols", function()
      local rows = { row("f1", "session.ts", { row("s1", "refresh") }) }

      assert.same({ "session.ts", "refresh" }, names(view.filter(rows, "session")))
    end)

    it("matches without regard to case", function()
      local rows = { row("f1", "session.ts", { row("s1", "Refresh") }) }

      assert.same({ "session.ts", "Refresh" }, names(view.filter(rows, "refresh")))
    end)

    describe("under sections", function()
      ---@param children changeset.Row[]
      ---@return changeset.Row
      local function tests_section(children)
        local section = row("#tests", "Tests", children)
        section.kind, section.files, section.added, section.removed = "section", 2, 7, 3
        return section
      end

      it("never keeps a section on its own label", function()
        local rows = { tests_section({ row("f1", "a_spec.lua"), row("f2", "b_spec.lua") }) }

        assert.same({}, view.filter(rows, "tests"))
      end)

      it("keeps a section for a matching file, with its whole-section totals", function()
        local rows = { tests_section({ row("f1", "a_spec.lua"), row("f2", "b_spec.lua") }) }

        local kept = view.filter(rows, "a_spec")[1]
        assert.same({ "Tests", "a_spec.lua" }, names({ kept }))
        assert.same({ 2, 7, 3 }, { kept.files, kept.added, kept.removed })
      end)

      it("keeps only the copy of a file whose symbol matches", function()
        local rows = {
          row("#implementation", "Implementation", { row("i", "a.lua", { sym("i1", "run", "Function") }) }),
          row("#docs", "Docs", { row("d", "a.lua", { sym("d1", "describe", "Function") }) }),
        }

        assert.same({ "Docs", "a.lua", "describe" }, names(view.filter(rows, "describe")))
      end)
    end)
  end)
  describe("by_kind", function()
    it("returns the whole tree when nothing is hidden", function()
      local rows = { row("f1", "session.ts", { sym("s1", "refresh", "Method") }) }

      assert.same({ "session.ts", "refresh" }, names(view.by_kind(rows, {})))
    end)

    it("drops a symbol of a hidden kind", function()
      local rows = {
        row("f1", "session.ts", { sym("s1", "refresh", "Method"), sym("s2", "TTL", "Variable") }),
      }

      assert.same({ "session.ts", "refresh" }, names(view.by_kind(rows, { Variable = true })))
    end)

    it("promotes a hidden symbol's children rather than taking them down with it", function()
      local rows = {
        row("f1", "session.ts", { sym("s1", "Store", "Class", { sym("s2", "refresh", "Method") }) }),
      }

      assert.same({ "session.ts", "refresh" }, names(view.by_kind(rows, { Class = true })))
    end)

    it("keeps a file row, which has no symbol kind to hide", function()
      local rows = { row("f1", "session.ts", { sym("s1", "TTL", "Variable") }) }

      assert.same({ "session.ts" }, names(view.by_kind(rows, { Variable = true })))
    end)

    it("keeps an orphan-hunk group, which names no symbol", function()
      local orphans = { id = "o", kind = "orphans", name = "Other changes", children = {} }
      local rows = { row("f1", "Makefile", { orphans }) }

      assert.same({ "Makefile", "Other changes" }, names(view.by_kind(rows, { Variable = true })))
    end)
  end)

  describe("kind_counts", function()
    it("counts nothing in a tree of files alone", function()
      assert.same({}, view.kind_counts({ row("f1", "Makefile") }))
    end)

    it("counts every symbol row of each kind, however deep", function()
      local rows = {
        row("f1", "session.ts", {
          sym("s1", "Store", "Class", { sym("s2", "refresh", "Method"), sym("s3", "TTL", "Variable") }),
        }),
        row("f2", "auth.ts", { sym("s4", "verify", "Method") }),
      }

      assert.same({ Class = 1, Method = 2, Variable = 1 }, view.kind_counts(rows))
    end)
  end)
  describe("hiding", function()
    it("names nothing when the hidden kinds are not in this tree", function()
      assert.same({}, view.hiding({ Method = 2 }, { Variable = true }))
    end)

    it("names the hidden kinds this tree actually has, in order", function()
      local counts = { Variable = 31, Method = 2, Field = 9 }

      assert.same({ "Field", "Variable" }, view.hiding(counts, { Variable = true, Field = true, Class = true }))
    end)
  end)

  describe("position", function()
    -- One row per line, as the renderer hands them back: a header, two files, the
    -- first with a symbol nested two deep, then a second header over a third file.
    local lines = {
      { depth = 0 },
      { depth = 1, path = "a.lua" },
      { depth = 2 },
      { depth = 3 },
      { depth = 1, path = "b.lua" },
      { depth = 2 },
      { depth = 0 },
      { depth = 1, path = "c.lua" },
    }

    it("places a line under the file it belongs to", function()
      assert.same({ 1, 3 }, { view.position(lines, 4) })
    end)

    it("counts a file's own row as that file", function()
      assert.same({ 2, 3 }, { view.position(lines, 5) })
    end)

    it("names no file on a header line", function()
      assert.same({ nil, 3 }, { view.position(lines, 7) })
    end)

    it("leaves a folded section's files out of the total", function()
      assert.same({ 1, 1 }, { view.position({ { depth = 0 }, { depth = 0 }, { depth = 1, path = "a.lua" } }, 3) })
    end)

    describe("with a file shown in two sections", function()
      local split = {
        { depth = 0 },
        { depth = 1, path = "a.rs" },
        { depth = 1, path = "b.rs" },
        { depth = 0 },
        { depth = 1, path = "a.rs" },
        { depth = 2 },
      }

      it("counts the file once", function()
        assert.equal(2, select(2, view.position(split, 1)))
      end)

      it("numbers the second copy, and the lines under it, as the file's first", function()
        assert.same({ 1, 1 }, { (view.position(split, 5)), (view.position(split, 6)) })
      end)

      it("names no file on the second header", function()
        assert.is_nil((view.position(split, 4)))
      end)
    end)

    it("counts a file shown in three sections once", function()
      local rows = {}
      for _, path in ipairs({ "a.rs", "b.rs", "a.rs", "a.rs" }) do
        vim.list_extend(rows, { { depth = 0 }, { depth = 1, path = path } })
      end

      assert.same({ 1, 2 }, { view.position(rows, 8) })
    end)

    it("names no file on a Comments row, nor counts one", function()
      local with_comments = {
        { depth = 0, kind = "section" },
        { depth = 1, kind = "comment", path = "a.lua" },
        { depth = 0, kind = "section" },
        { depth = 1, kind = "file", path = "a.lua" },
      }

      assert.same({ nil, 1 }, { view.position(with_comments, 2) })
    end)

    it("has no position on an empty tree", function()
      assert.same({ nil, 0 }, { view.position({}, 1) })
    end)
  end)
  ---Lay `rows` out in `v` with the cursor on `cursor`.
  ---@param v changeset.View
  ---@param rows changeset.Row[]
  ---@param cursor integer?
  ---@return string[] names The name on each line.
  ---@return integer lnum Where the cursor lands.
  local function show(v, rows, cursor)
    local lines, lnum = v:show(rows, {
      icon = function()
        return "", ""
      end,
      width = 60,
      cursor = cursor or 1,
    })
    return vim.tbl_map(function(line)
      return line.row.name
    end, lines), lnum
  end

  ---@return changeset.View
  local function fresh()
    return view.new({ collapsed = {}, chains = {} }, {})
  end

  -- 1 Implementation, 2 mod.lua, 3 Store › load, 4 Other changes, 5 L30,
  -- 6 Tests, 7 mod_spec.lua, 8 Other changes, 9 L2.
  local ROWS = Rows.build({ Changes.file("mod.lua", { 5, 30 }), Changes.file("mod_spec.lua", { 2 }) }, {
    ["mod.lua"] = { Changes.sym("Store", "Class", 0, 1, 10), Changes.sym("load", "Method", 1, 3, 8) },
    ["mod_spec.lua"] = {},
  })
  local FILES_ONLY = { "Implementation", "mod.lua", "Tests", "mod_spec.lua" }
  local RS = "src/session.rs"
  local RS_SYMBOLS = {
    Changes.sym("load", "Function", 0, 1, 1),
    Changes.sym("tests", "Module", 0, 3, 6),
    Changes.sym("refreshes", "Function", 1, 4, 5),
  }
  -- 1 Implementation, 2 session.rs, 3 load, 4 Tests, 5 session.rs, 6 tests › refreshes.
  local SPLIT = Rows.build({ Changes.file(RS, { 1, 4 }) }, { [RS] = RS_SYMBOLS })

  describe("View folds", function()
    it("shows a row's children until something folds it", function()
      assert.same({ "Implementation", "mod.lua", "Store › load" }, vim.list_slice(show(fresh(), ROWS), 1, 3))
    end)

    it("folds a row whose children are showing, and opens it again", function()
      local v = fresh()
      show(v, ROWS)

      assert.same({ nil, true }, { v:step_out(2) })
      assert.same({ "Implementation", "mod.lua", "Tests" }, vim.list_slice(show(v, ROWS), 1, 3))

      assert.is_true(v:open(2))
      assert.same({ "Implementation", "mod.lua", "Store › load" }, vim.list_slice(show(v, ROWS), 1, 3))
    end)

    it("folds every file", function()
      local v = fresh()
      v:fold_files(ROWS)

      assert.same(FILES_ONLY, show(v, ROWS))
    end)

    it("unfolds every file but keeps a folded section folded", function()
      local v = fresh()
      v:fold_files(ROWS)
      show(v, ROWS)
      v:step_out(3)

      v:unfold_files()

      assert.same({ "Implementation", "mod.lua", "Store › load", "Other changes", "L30", "Tests" }, show(v, ROWS))
    end)

    it("keeps a folded section folded under unfold_files across a rebuild that empties it", function()
      -- 1 Implementation, 2 mod.lua, 3 Docs, 4 README.md.
      local with_docs = Rows.build({ Changes.file("mod.lua", { 5 }), Changes.file("README.md", { 1 }) }, {})
      local v = fresh()
      v:fold_files(with_docs)
      show(v, with_docs)
      v:step_out(3)
      show(v, Rows.build({ Changes.file("mod.lua", { 5 }) }, {}))

      v:unfold_files()

      local shown = show(v, with_docs)
      assert.equal("Docs", shown[#shown])
    end)

    it("keeps the Comments section folded under unfold_files", function()
      local review_comment = { path = "mod.lua", line = 5, body = "why?" }
      local with_comments = { assert(Rows.comments({ review_comment })), unpack(ROWS) }
      local v = fresh()
      show(v, with_comments)
      v:step_out(1)

      v:unfold_files()

      assert.same({ "Comments", "Implementation" }, vim.list_slice(show(v, with_comments), 1, 2))
    end)

    it("folds and unfolds a section from its header", function()
      local v = fresh()
      local expanded = show(v, ROWS)

      assert.same({ nil, true }, { v:step_out(1) })
      assert.same({ "Implementation", "Tests" }, vim.list_slice(show(v, ROWS), 1, 2))

      assert.is_true(v:open(1))
      assert.same(expanded, show(v, ROWS))
    end)

    it("folds each copy of a file split across sections on its own", function()
      local v = fresh()
      show(v, SPLIT)

      v:step_out(5)

      assert.same({ "Implementation", RS, "load", "Tests", RS }, show(v, SPLIT))
    end)

    it("opens a shut chain's rows rather than unfolding the row", function()
      local v = fresh()
      show(v, ROWS)

      assert.is_true(v:open(3))

      assert.same({ "Store", "load", "Other changes" }, vim.list_slice(show(v, ROWS), 3, 5))
    end)

    it("folds an opened chain's head, then steps out of it, leaving the chain open", function()
      local v = fresh()
      show(v, ROWS)
      v:open(3)
      show(v, ROWS)
      v:open(3)
      show(v, ROWS)

      assert.same({ nil, true }, { v:step_out(3) })
      assert.same({ "Store", "Other changes" }, vim.list_slice(show(v, ROWS), 3, 4))
      assert.same({ 2, false }, { v:step_out(3) })
      assert.equal("Store", show(v, ROWS)[3])
    end)

    it("does nothing on a line with no row", function()
      local v = fresh()
      show(v, ROWS)

      assert.is_false(v:open(99))
      assert.same({ nil, false }, { v:step_out(99) })
    end)
  end)

  describe("View reveal", function()
    it("unfolds only the block of two same-named siblings that holds the row", function()
      -- Two `impl Store` blocks, as Rust splits one type's methods.
      local rows = Rows.build({ Changes.file("src/store.rs", { 3, 6, 13 }) }, {
        ["src/store.rs"] = {
          Changes.sym("impl Store", "Object", 0, 1, 8),
          Changes.sym("load", "Method", 1, 2, 4),
          Changes.sym("drop", "Method", 1, 5, 7),
          Changes.sym("impl Store", "Object", 0, 10, 15),
          Changes.sym("save", "Method", 1, 12, 14),
        },
      })
      local first, second = rows[1].children[1].children[1], rows[1].children[1].children[2]
      local v = view.new({ collapsed = { [first.id] = true, [second.id] = true }, chains = {} }, {})

      v:reveal(second.children[1].id)

      assert.same({ "Implementation", "src/store.rs", "impl Store", "impl Store › save" }, show(v, rows))
    end)
  end)

  describe("View step_out", function()
    it("steps out to the parent when nothing is showing below the row", function()
      local v = fresh()
      show(v, ROWS)

      assert.same({ 2, false }, { v:step_out(3) })
    end)

    it("steps out past the siblings sitting between a row and its parent", function()
      local v = fresh()
      show(v, ROWS)
      v:step_out(4)
      show(v, ROWS)

      assert.same({ 2, false }, { v:step_out(4) })
    end)

    it("steps out of a shut file to its section header", function()
      local v = fresh()
      v:fold_files(ROWS)
      show(v, ROWS)

      assert.same({ 1, false }, { v:step_out(2) })
    end)

    it("does nothing on a shut section header", function()
      local v = fresh()
      show(v, ROWS)
      v:step_out(1)
      show(v, ROWS)

      assert.same({ nil, false }, { v:step_out(1) })
    end)
  end)

  describe("View narrow", function()
    it("matches a query as plain text, not a pattern", function()
      local v = fresh()
      v:narrow("(")

      assert.same({}, show(v, ROWS))
    end)

    it("keeps no file on screen for a match only a hidden kind holds", function()
      local rows = Rows.build({ Changes.file("mod.lua", { 2, 6 }) }, {
        ["mod.lua"] = { Changes.sym("needle", "Variable", 0, 1, 3), Changes.sym("other", "Function", 0, 5, 7) },
      })
      local v = fresh()
      v:hide({ Variable = true })
      v:narrow("needle")

      assert.same({}, show(v, rows))
    end)
  end)

  describe("View hide", function()
    it("leaves a hidden kind's row out but keeps its children", function()
      local v = fresh()
      v:hide({ Class = true })

      assert.same({ "Implementation", "mod.lua", "load", "Other changes" }, vim.list_slice(show(v, ROWS), 1, 4))
      assert.same({ Class = true }, v:hidden())
    end)
  end)

  describe("View show", function()
    -- 1 Tests, 2 session.rs, 3 tests › refreshes.
    local TESTS_ONLY = Rows.build({ Changes.file(RS, { 4 }) }, { [RS] = RS_SYMBOLS })
    -- 1 Implementation, 2 mod.lua, 3 Store › load, 4 Tests, 5 mod_spec.lua, 6 Other changes, 7 L2.
    local NO_L30 = Rows.build({ Changes.file("mod.lua", { 5 }), Changes.file("mod_spec.lua", { 2 }) }, {
      ["mod.lua"] = { Changes.sym("Store", "Class", 0, 1, 10), Changes.sym("load", "Method", 1, 3, 8) },
      ["mod_spec.lua"] = {},
    })

    it("puts the cursor on its row's new line when the redraw moved it", function()
      local v = fresh()
      show(v, ROWS)

      assert.equal(5, select(2, show(v, NO_L30, 7)))
    end)

    it("holds the cursor's line when the row it sat on is gone", function()
      local v = fresh()
      show(v, ROWS)

      assert.equal(5, select(2, show(v, NO_L30, 5)))
    end)

    it("clamps to the last row when the tree shrank past the cursor", function()
      local v = fresh()
      show(v, ROWS)

      assert.equal(3, select(2, show(v, TESTS_ONLY, 9)))
    end)

    it("lands on the first row when the tree was empty before", function()
      assert.equal(1, select(2, show(fresh(), ROWS, 0)))
    end)

    it("moves a file row gone from screen to its path's row under another section", function()
      local v = fresh()
      show(v, SPLIT)
      -- 1 Implementation, 2 a.lua, 3 Other changes, 4 L1, 5 Tests, 6 session.rs, 7 tests › refreshes.
      local moved = Rows.build(
        { Changes.file("a.lua", { 1 }), Changes.file(RS, { 4 }) },
        { ["a.lua"] = {}, [RS] = RS_SYMBOLS }
      )

      assert.equal(6, select(2, show(v, moved, 2)))
    end)

    it("holds the line for a gone symbol row even when its file shows elsewhere", function()
      local v = fresh()
      show(v, SPLIT)

      assert.equal(3, select(2, show(v, TESTS_ONLY, 3)))
    end)

    it("holds the line for a gone reading-symbols placeholder, which is a file-kind row below depth 1", function()
      local v = fresh()
      -- 1 Implementation, 2 session.rs, 3 the placeholder.
      show(v, Rows.build({ Changes.file(RS, { 4 }) }, {}))

      assert.equal(3, select(2, show(v, TESTS_ONLY, 3)))
    end)

    it("hands back the row on each line", function()
      local v = fresh()
      show(v, ROWS)

      assert.equal("mod.lua", v:row(2).name)
      assert.equal(9, #v:visible())
    end)
  end)

  describe("View step", function()
    local v = fresh()
    v:fold_files(ROWS)
    show(v, ROWS)

    it("skips a section header going down", function()
      assert.equal(4, v:step(2, 1))
    end)

    it("skips a section header going up", function()
      assert.equal(2, v:step(4, -1))
    end)

    it("stays put past the last row", function()
      assert.equal(4, v:step(4, 1))
    end)

    it("stays put when only a header lies above", function()
      assert.equal(2, v:step(2, -1))
    end)

    it("lands on the next file from a header", function()
      assert.equal(2, v:step(1, 1))
    end)
  end)

  describe("View step_section", function()
    -- 1 Implementation, 2 mod.lua, 3 Tests (folded), 4 Docs, 5 README.md.
    local THREE_SECTIONS = Rows.build(
      { Changes.file("mod.lua", { 5 }), Changes.file("mod_spec.lua", { 2 }), Changes.file("README.md", { 1 }) },
      {}
    )
    local v = fresh()
    v:fold_files(THREE_SECTIONS)
    show(v, THREE_SECTIONS)
    v:step_out(3)
    show(v, THREE_SECTIONS)

    it("goes down from a file to the next header, a folded one included", function()
      assert.equal(3, v:step_section(2, 1))
    end)

    it("goes down from a folded header to the one right under it", function()
      assert.equal(4, v:step_section(3, 1))
    end)

    it("stays put at the last header", function()
      assert.equal(4, v:step_section(4, 1))
    end)

    it("stays put below the last header", function()
      assert.equal(5, v:step_section(5, 1))
    end)

    it("goes up from a file to its own section's header", function()
      assert.equal(4, v:step_section(5, -1))
    end)

    it("goes up from a header to the previous one", function()
      assert.equal(1, v:step_section(3, -1))
    end)

    it("stays put at the first header", function()
      assert.equal(1, v:step_section(1, -1))
    end)
  end)

  describe("for_root", function()
    it("gives a second view of the same root the first view's folds", function()
      local first = view.for_root("/repo/shared-folds", {})
      show(first, ROWS)
      first:step_out(2)

      assert.same(
        { "Implementation", "mod.lua", "Tests" },
        vim.list_slice(show(view.for_root("/repo/shared-folds", {}), ROWS), 1, 3)
      )
    end)

    it("starts a new root with Generated folded", function()
      local generated = Changes.file("gen.lua", { 1 })
      generated.section = "generated"
      local rows = Rows.build({ Changes.file("mod.lua", { 5 }), generated }, {})

      assert.same({ "Generated" }, vim.list_slice(show(view.for_root("/repo/generated-folded", {}), rows), 4))
    end)

    it("keeps Generated folded when every file unfolds", function()
      local generated = Changes.file("gen.lua", { 1 })
      generated.section = "generated"
      local rows = Rows.build({ Changes.file("mod.lua", { 5 }), generated }, {})
      local v = view.for_root("/repo/generated-unfold-files", {})

      v:unfold_files()

      assert.same({ "Generated" }, vim.list_slice(show(v, rows), 4))
    end)
  end)
end)
