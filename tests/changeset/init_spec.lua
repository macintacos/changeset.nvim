local changeset = require("plugins.changeset")

describe("changeset", function()
  describe("_next_action", function()
    it("opens and focuses when the sidebar is not showing", function()
      assert.equal("open", changeset._next_action({ visible = false, focused = false }))
    end)

    it("focuses the sidebar when it is showing but the cursor is elsewhere", function()
      assert.equal("focus", changeset._next_action({ visible = true, focused = false }))
    end)

    it("closes the sidebar when the cursor is already in it", function()
      assert.equal("close", changeset._next_action({ visible = true, focused = true }))
    end)
  end)

  describe("_outward", function()
    it("shuts a row whose children are on screen", function()
      assert.equal("collapse", changeset._outward({ { depth = 0 }, { depth = 1 } }, 1))
    end)

    it("steps out to the parent when nothing is showing below the row", function()
      local action, lnum = changeset._outward({ { depth = 0 }, { depth = 1 } }, 2)
      assert.equal("parent", action)
      assert.equal(1, lnum)
    end)

    it("steps out past the siblings sitting between a row and its parent", function()
      local action, lnum = changeset._outward({ { depth = 0 }, { depth = 1 }, { depth = 2 }, { depth = 2 } }, 4)
      assert.equal("parent", action)
      assert.equal(2, lnum)
    end)

    it("does nothing on a shut file row, which has no parent to step out to", function()
      assert.is_nil(changeset._outward({ { depth = 0 }, { depth = 0 } }, 1))
    end)
  end)
end)
