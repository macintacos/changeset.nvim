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
    end)

    it("resolves numeric LSP kinds to their names", function()
      local items = symbols.flatten({ sym("f", KIND.Function, 0) })

      assert.equal("Function", items[1].kind)
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
      }, { Function = true })

      assert.same({ "kept" }, field(items, "name"))
      assert.same({ 0 }, field(items, "depth"))
    end)

    describe("under a callable", function()
      -- Keeps every kind used here, so only the nesting can drop one.
      local CODE = {
        Class = true,
        Constant = true,
        Constructor = true,
        Function = true,
        Method = true,
        Property = true,
        Variable = true,
      }

      for _, kind in ipairs({ "Function", "Method", "Constructor" }) do
        it("drops a " .. kind .. "'s locals, parameters and object keys", function()
          local items = symbols.flatten({
            sym("callable", KIND[kind], 0, { sym("token", KIND.Variable, 1), sym("status", KIND.Property, 2) }),
          }, CODE)

          assert.same({ "callable" }, field(items, "name"))
        end)
      end

      it("keeps the callables and types a function declares", function()
        local items = symbols.flatten({
          sym("outer", KIND.Function, 0, { sym("helper", KIND.Function, 1), sym("Local", KIND.Class, 2) }),
        }, CODE)

        assert.same({ "outer", "helper", "Local" }, field(items, "name"))
        assert.same({ 0, 1, 1 }, field(items, "depth"))
      end)

      it("keeps a callable declared inside a local it drops", function()
        local items = symbols.flatten({
          sym("outer", KIND.Function, 0, { sym("handler", KIND.Variable, 1, { sym("inner", KIND.Function, 2) }) }),
        }, CODE)

        assert.same({ "outer", "inner" }, field(items, "name"))
        assert.same({ 0, 1 }, field(items, "depth"))
      end)

      it("drops the locals of a function held in a variable", function()
        local items = symbols.flatten({
          sym("handler", KIND.Variable, 0, { sym("token", KIND.Variable, 1), sym("status", KIND.Constant, 2) }),
        }, CODE)

        assert.same({ "handler" }, field(items, "name"))
      end)

      it("drops the locals of a function held in a class field", function()
        local items = symbols.flatten({
          sym("Sweeper", KIND.Class, 0, { sym("sweep", KIND.Property, 1, { sym("dropped", KIND.Variable, 2) }) }),
        }, CODE)

        assert.same({ "Sweeper", "sweep" }, field(items, "name"))
      end)

      it("drops a getter's locals", function()
        local items = symbols.flatten({
          sym("Pool", KIND.Class, 0, { sym("size", KIND.Property, 1, { sym("n", KIND.Variable, 2) }) }),
        }, CODE)

        assert.same({ "Pool", "size" }, field(items, "name"))
      end)

      it("keeps an object literal's keys", function()
        local items = symbols.flatten({
          sym("DEFAULTS", KIND.Constant, 0, {
            sym("keymaps", KIND.Property, 1, { sym("jump", KIND.Property, 2) }),
            sym("onOpen", KIND.Method, 3),
          }),
        }, CODE)

        assert.same({ "DEFAULTS", "keymaps", "jump", "onOpen" }, field(items, "name"))
      end)

      it("keeps the members of a class declared inside a function", function()
        local items = symbols.flatten({
          sym("outer", KIND.Function, 0, { sym("Local", KIND.Class, 1, { sym("field", KIND.Property, 2) }) }),
        }, CODE)

        assert.same({ "outer", "Local", "field" }, field(items, "name"))
      end)
    end)

    it("reads a flat SymbolInformation response", function()
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
      assert.same({ 0 }, field(items, "depth"))
      assert.equal(5, items[1].lnum)
      assert.equal(5, items[1].range_lnum)
    end)
    it("nests a flat SymbolInformation response by the ranges that hold each symbol", function()
      local function info(name, kind, first, last)
        return {
          name = name,
          kind = kind,
          location = {
            uri = vim.uri_from_fname("/tmp/session.py"),
            range = { start = { line = first, character = 0 }, ["end"] = { line = last, character = 0 } },
          },
        }
      end

      local items = symbols.flatten({
        info("refresh", KIND.Method, 4, 9),
        info("Session", KIND.Class, 0, 19),
        info("TTL", KIND.Constant, 21, 21),
      })

      assert.same({ "Session", "refresh", "TTL" }, field(items, "name"))
      assert.same({ 0, 1, 0 }, field(items, "depth"))
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
