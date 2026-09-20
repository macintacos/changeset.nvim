local view = require("plugins.changetree.view")

---@param id string
---@param name string
---@param children changetree.Row[]?
---@return changetree.Row
local function row(id, name, children)
  return { id = id, name = name, children = children or {} }
end

---Names of a row tree, depth-first, parents before children.
---@param rows changetree.Row[]
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
---@param children changetree.Row[]?
---@return changetree.Row
local function sym(id, name, kind, children)
  return { id = id, kind = "symbol", name = name, symbol_kind = kind, children = children or {} }
end

describe("changetree.view", function()
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

    it("drops a subtree with nothing matching in it", function()
      local rows = {
        row("f1", "session.ts", { row("s1", "refresh") }),
        row("f2", "auth.ts", { row("s2", "verify") }),
      }

      assert.same({ "session.ts", "refresh" }, names(view.filter(rows, "refresh")))
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
      local rows = {
        row("f1", "Makefile", { { id = "o", kind = "orphans", name = "Other changes", children = {} } }),
      }

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
end)
