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
end)
