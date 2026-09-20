local prtree = require("plugins.prtree")

describe("prtree", function()
  describe("_next_action", function()
    it("opens and focuses when the sidebar is not showing", function()
      assert.equal("open", prtree._next_action({ visible = false, focused = false }))
    end)

    it("focuses the sidebar when it is showing but the cursor is elsewhere", function()
      assert.equal("focus", prtree._next_action({ visible = true, focused = false }))
    end)

    it("closes the sidebar when the cursor is already in it", function()
      assert.equal("close", prtree._next_action({ visible = true, focused = true }))
    end)
  end)
end)
