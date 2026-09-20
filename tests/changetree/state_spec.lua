local state = require("plugins.changetree.state")

describe("changetree.state", function()
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
end)
