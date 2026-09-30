local state = require("changeset.state")

describe("changeset.state", function()
  describe("folds", function()
    it("shows a row's children until something collapses it", function()
      local st = state.new()

      assert.is_false(state.is_collapsed(st, "session.ts"))
    end)

    it("hides and reveals a row's children", function()
      local st = state.new()

      state.set_collapsed(st, "session.ts", true)
      assert.is_true(state.is_collapsed(st, "session.ts"))

      state.set_collapsed(st, "session.ts", false)
      assert.is_false(state.is_collapsed(st, "session.ts"))
    end)

    it("collapses every row it is handed", function()
      local st = state.new()

      state.collapse_all(st, { "api.ts", "auth.ts" })

      assert.is_true(state.is_collapsed(st, "api.ts"))
      assert.is_true(state.is_collapsed(st, "auth.ts"))
    end)

    it("expands every row but those it is told to keep folded", function()
      local st = state.new()
      state.collapse_all(st, { "#tests", "#tests\0a_spec.lua" })

      state.expand_all(st, { "#tests", "#docs" })

      assert.is_true(state.is_collapsed(st, "#tests"))
      assert.is_false(state.is_collapsed(st, "#docs"))
      assert.is_false(state.is_collapsed(st, "#tests\0a_spec.lua"))
    end)

    it("tracks an opened-out chain separately from a collapsed row", function()
      local st = state.new()

      state.set_chain_open(st, "session.ts\0Store", true)

      assert.is_true(state.is_chain_open(st, "session.ts\0Store"))
      assert.is_false(state.is_collapsed(st, "session.ts\0Store"))
    end)
  end)

  describe("_reanchor", function()
    local impl = { id = "#implementation\0session.rs", kind = "file", depth = 1, path = "session.rs" }
    local tests = { id = "#tests\0session.rs", kind = "file", depth = 1, path = "session.rs" }
    local other = { id = "#implementation\0api.rs", kind = "file", depth = 1, path = "api.rs" }

    ---Rows carrying only the id `_reanchor` matches on first.
    ---@param ... string
    ---@return changeset.Row[]
    local function with_ids(...)
      return vim.tbl_map(function(id)
        return { id = id }
      end, { ... })
    end

    it("puts the cursor on its row's new line when the redraw moved it", function()
      assert.equal(3, state._reanchor({ other, tests, impl }, impl, 2))
    end)

    it("holds the cursor's line when the row it sat on is gone", function()
      assert.equal(2, state._reanchor(with_ids("a", "b", "c"), with_ids("gone")[1], 2))
    end)

    it("clamps to the last row when the tree shrank past the cursor", function()
      assert.equal(1, state._reanchor({ other }, with_ids("gone")[1], 7))
    end)

    it("lands on the first row when the tree was empty before", function()
      assert.equal(1, state._reanchor({ other }, nil, 0))
    end)

    it("moves a file row gone from screen to its path's row under another section", function()
      assert.equal(2, state._reanchor({ other, tests }, impl, 1))
    end)

    it("holds the line for a gone symbol row even when its file shows elsewhere", function()
      local sym = { id = impl.id .. "\0refresh", kind = "symbol", depth = 2, path = "session.rs" }

      assert.equal(1, state._reanchor({ other, tests }, sym, 1))
    end)

    it("holds the line for a gone reading-symbols placeholder, which is a file-kind row below depth 1", function()
      local placeholder = { id = impl.id .. "\0#pending", kind = "file", depth = 2, path = "session.rs" }

      assert.equal(1, state._reanchor({ other, tests }, placeholder, 1))
    end)
  end)

  describe("_outward", function()
    ---Rows carrying only the depth `_outward` reads.
    ---@param ... integer
    ---@return changeset.Row[]
    local function at_depths(...)
      local rows = {}
      for i, depth in ipairs({ ... }) do
        rows[i] = { depth = depth }
      end
      return rows
    end

    it("shuts a row whose children are on screen", function()
      assert.equal("collapse", state._outward(at_depths(0, 1), 1))
    end)

    it("steps out to the parent when nothing is showing below the row", function()
      local action, parent_lnum = state._outward(at_depths(0, 1), 2)
      assert.equal("parent", action)
      assert.equal(1, parent_lnum)
    end)

    it("steps out past the siblings sitting between a row and its parent", function()
      local action, parent_lnum = state._outward(at_depths(0, 1, 2, 2), 4)
      assert.equal("parent", action)
      assert.equal(2, parent_lnum)
    end)

    it("does nothing on a shut section header", function()
      assert.is_nil(state._outward(at_depths(0, 0), 1))
    end)
  end)

  ---Rows carrying only the kind `_step` and `_section` read.
  ---@param ... "section"|"file"
  ---@return changeset.Row[]
  local function of_kinds(...)
    return vim.tbl_map(function(kind)
      return { kind = kind }
    end, { ... })
  end

  describe("_step", function()
    local ROWS = of_kinds("section", "file", "section", "file")

    it("skips a section header going down", function()
      assert.equal(4, state._step(ROWS, 2, 1))
    end)

    it("skips a section header going up", function()
      assert.equal(2, state._step(ROWS, 4, -1))
    end)

    it("stays put past the last row", function()
      assert.equal(4, state._step(ROWS, 4, 1))
    end)

    it("stays put when only a header lies above", function()
      assert.equal(2, state._step(ROWS, 2, -1))
    end)

    it("lands on the next file from a header", function()
      assert.equal(2, state._step(ROWS, 1, 1))
    end)
  end)

  describe("_section", function()
    -- Row 3 is a folded section: nothing sits between its header and the next.
    local ROWS = of_kinds("section", "file", "section", "section", "file")

    it("goes down from a file to the next header, a folded one included", function()
      assert.equal(3, state._section(ROWS, 2, 1))
    end)

    it("goes down from a folded header to the one right under it", function()
      assert.equal(4, state._section(ROWS, 3, 1))
    end)

    it("stays put at the last header", function()
      assert.equal(4, state._section(ROWS, 4, 1))
    end)

    it("stays put below the last header", function()
      assert.equal(5, state._section(ROWS, 5, 1))
    end)

    it("goes up from a file to its own section's header", function()
      assert.equal(4, state._section(ROWS, 5, -1))
    end)

    it("goes up from a header to the previous one", function()
      assert.equal(1, state._section(ROWS, 3, -1))
    end)

    it("stays put at the first header", function()
      assert.equal(1, state._section(ROWS, 1, -1))
    end)
  end)

  describe("_nearest", function()
    local IDS = { "a.lua", "a.lua\0Store", "b.lua" }

    it("finds the line of the row itself", function()
      assert.equal(2, state._nearest(IDS, "a.lua\0Store"))
    end)

    it("falls back to the deepest ancestor on screen when the row is hidden", function()
      assert.equal(2, state._nearest(IDS, "a.lua\0Store\0load\0inner"))
      assert.equal(3, state._nearest(IDS, "b.lua\0#orphans\0#orphan:4"))
    end)

    it("sends a hidden orphan to its group when the group is the deepest row shown", function()
      local ids = { "a.lua", "a.lua\0#orphans" }

      assert.equal(2, state._nearest(ids, "a.lua\0#orphans\0#orphan:4"))
    end)

    it("does not take a row whose name merely starts the same for an ancestor", function()
      assert.equal(1, state._nearest(IDS, "a.lua\0Storefront"))
    end)

    it("finds nothing when no row on screen is related", function()
      assert.is_nil(state._nearest(IDS, "c.lua"))
    end)
  end)
end)
