local symbols = require("changeset.symbols")

local KIND = vim.lsp.protocol.SymbolKind

---A `DocumentSymbol` named `name` declared on (0-based) `line`.
---@param name string
---@param kind integer
---@param line integer
---@param children table[]?
---@return table
local function sym(name, kind, line, children)
  local start = { line = line, character = 0 }
  return {
    name = name,
    kind = kind,
    range = { start = start, ["end"] = { line = line, character = 80 } },
    selectionRange = { start = start, ["end"] = { line = line, character = #name } },
    children = children,
  }
end

---Collect one field across a list of items.
---@param items table[]
---@param key string
---@return any[]
local function field(items, key)
  local out = {}
  for i, item in ipairs(items) do
    out[i] = item[key]
  end
  return out
end

describe("changeset.symbols", function()
  describe("flatten", function()
    it("walks a nested tree depth-first, recording depth", function()
      local items = symbols.flatten({
        sym("outer", KIND.Function, 0, { sym("inner", KIND.Variable, 1) }),
        sym("after", KIND.Function, 2),
      })

      assert.same({ "outer", "inner", "after" }, field(items, "name"))
      assert.same({ 0, 1, 0 }, field(items, "depth"))
    end)

    it("records the body range separately from the name range", function()
      local fn = sym("wrapper", KIND.Function, 4)
      fn.range["end"] = { line = 20, character = 1 }

      local items = symbols.flatten({ fn })

      assert.equal(5, items[1].range_lnum)
      assert.equal(21, items[1].range_end_lnum)
      assert.equal(5, items[1].end_lnum)
    end)

    it("resolves numeric LSP kinds to their names", function()
      local items = symbols.flatten({ sym("f", KIND.Function, 0) })

      assert.equal("Function", items[1].kind)
    end)

    it("closes the last child's branch and tees the others", function()
      local items = symbols.flatten({
        sym("root", KIND.Function, 0, {
          sym("first", KIND.Variable, 1),
          sym("last", KIND.Function, 2, { sym("leaf", KIND.Variable, 3) }),
        }),
      })

      assert.same({ "", "├─", "└─", "  └─" }, field(items, "guides"))
    end)

    it("carries a bar past ancestors that still have siblings below", function()
      local items = symbols.flatten({
        sym("root", KIND.Function, 0, {
          sym("first", KIND.Function, 1, { sym("leaf", KIND.Variable, 2) }),
          sym("last", KIND.Variable, 3),
        }),
      })

      assert.same({ "", "├─", "│ └─", "└─" }, field(items, "guides"))
    end)

    it("builds a breadcrumb from ancestor names", function()
      local items = symbols.flatten({
        sym("root", KIND.Function, 0, {
          sym("mid", KIND.Function, 1, { sym("leaf", KIND.Variable, 2) }),
        }),
      })

      assert.same({ "", "root", "root › mid" }, field(items, "crumb"))
    end)

    it("orders siblings by position, not by response order", function()
      local items = symbols.flatten({
        sym("third", KIND.Function, 20),
        sym("first", KIND.Function, 2),
        sym("second", KIND.Function, 10),
      })

      assert.same({ "first", "second", "third" }, field(items, "name"))
    end)

    it("drops a filtered kind but keeps its children", function()
      local items = symbols.flatten({
        sym("some_table", KIND.Object, 0, { sym("kept", KIND.Function, 1) }),
      }, { kinds = { Function = true } })

      assert.same({ "kept" }, field(items, "name"))
      assert.same({ 0 }, field(items, "depth"))
      assert.same({ "" }, field(items, "crumb"))
      assert.same({ "" }, field(items, "guides"))
    end)

    it("converts character positions to byte columns", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local é = fn" })

      local item = sym("fn", KIND.Function, 0)
      item.selectionRange.start.character = 10

      local items = symbols.flatten({ item }, { bufnr = buf })

      -- "é" is two bytes, so UTF-16 character 10 sits at byte 11 (col 12).
      assert.equal(12, items[1].col)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("reads a flat SymbolInformation response, crumbing its containerName", function()
      local items = symbols.flatten({
        {
          name = "method",
          kind = KIND.Method,
          containerName = "Widget",
          location = {
            uri = vim.uri_from_fname("/tmp/widget.lua"),
            range = { start = { line = 4, character = 2 }, ["end"] = { line = 4, character = 8 } },
          },
        },
      })

      assert.same({ "method" }, field(items, "name"))
      assert.same({ "Widget" }, field(items, "crumb"))
      assert.same({ 0 }, field(items, "depth"))
      assert.equal(5, items[1].lnum)
    end)
  end)

  describe("fit", function()
    it("leaves a crumb that already fits", function()
      assert.equal("root › mid", symbols.fit("root › mid", 40))
    end)

    it("drops leading segments and marks the trim", function()
      assert.equal("… › mid › leaf", symbols.fit("root › outer › mid › leaf", 16))
    end)

    it("truncates a single oversized segment from the left", function()
      assert.equal("…ngSymbolName", symbols.fit("someVeryLongSymbolName", 13))
    end)

    it("splits on a caller-given separator", function()
      assert.equal("…/changeset", symbols.fit("lua/plugins/changeset", 15, "/"))
    end)
  end)
end)
