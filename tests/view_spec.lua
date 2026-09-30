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

    it("has no position on an empty tree", function()
      assert.same({ nil, 0 }, { view.position({}, 1) })
    end)
  end)
end)
