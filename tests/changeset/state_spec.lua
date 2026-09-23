local state = require("plugins.changeset.state")

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

    it("expands everything at once", function()
      local st = state.new()
      state.collapse_all(st, { "api.ts", "auth.ts" })

      state.expand_all(st)

      assert.is_false(state.is_collapsed(st, "api.ts"))
      assert.is_false(state.is_collapsed(st, "auth.ts"))
    end)

    it("tracks an opened-out chain separately from a collapsed row", function()
      local st = state.new()

      state.set_chain_open(st, "session.ts\0Store", true)

      assert.is_true(state.is_chain_open(st, "session.ts\0Store"))
      assert.is_false(state.is_collapsed(st, "session.ts\0Store"))
    end)
  end)

  describe("_reanchor", function()
    it("follows a row to its new line when the rebuild moved it", function()
      local ids = { "api.ts", "auth.ts", "session.ts" }

      assert.equal(3, state._reanchor(ids, "session.ts", 2))
    end)

    it("holds the cursor's line when the row it sat on is gone", function()
      local ids = { "api.ts", "auth.ts", "session.ts" }

      assert.equal(2, state._reanchor(ids, "deleted.ts", 2))
    end)

    it("clamps to the last row when the tree shrank past the cursor", function()
      local ids = { "api.ts" }

      assert.equal(1, state._reanchor(ids, "gone.ts", 7))
    end)

    it("lands on the first row when the tree was empty before", function()
      assert.equal(1, state._reanchor({ "api.ts" }, nil, 0))
    end)
  end)

  describe("_outward", function()
    it("shuts a row whose children are on screen", function()
      assert.equal("collapse", state._outward({ { depth = 0 }, { depth = 1 } }, 1))
    end)

    it("steps out to the parent when nothing is showing below the row", function()
      local action, parent_lnum = state._outward({ { depth = 0 }, { depth = 1 } }, 2)
      assert.equal("parent", action)
      assert.equal(1, parent_lnum)
    end)

    it("steps out past the siblings sitting between a row and its parent", function()
      local action, parent_lnum = state._outward({ { depth = 0 }, { depth = 1 }, { depth = 2 }, { depth = 2 } }, 4)
      assert.equal("parent", action)
      assert.equal(2, parent_lnum)
    end)

    it("does nothing on a shut file row, which has no parent to step out to", function()
      assert.is_nil(state._outward({ { depth = 0 }, { depth = 0 } }, 1))
    end)
  end)
  describe("_nearest", function()
    local IDS = { "a.lua", "a.lua\0Store", "b.lua" }

    it("finds the line of the row itself", function()
      assert.equal(2, state._nearest(IDS, "a.lua\0Store"))
    end)

    it("falls back to the deepest ancestor on screen when the row is hidden", function()
      assert.equal(2, state._nearest(IDS, "a.lua\0Store\0load\0inner"))
      assert.equal(3, state._nearest(IDS, "b.lua\0#orphans"))
    end)

    it("does not take a row whose name merely starts the same for an ancestor", function()
      assert.equal(1, state._nearest(IDS, "a.lua\0Storefront"))
    end)

    it("finds nothing when no row on screen is related", function()
      assert.is_nil(state._nearest(IDS, "c.lua"))
    end)
  end)
end)
