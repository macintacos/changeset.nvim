local prtree = require("plugins.prtree")

describe("prtree", function()
  describe("_review_gutter", function()
    it("points the gutter at the fork point the tree is measured against", function()
      local seen
      local gitsigns = {
        change_base = function(base, global)
          seen = { base, global }
        end,
      }

      prtree._review_gutter(gitsigns, "abc123", true)

      assert.same({ "abc123", true }, seen)
    end)

    it("leaves the gutter where the user left it when the setting is off", function()
      local gitsigns = {
        change_base = function()
          error("the gutter was moved with the setting off")
        end,
      }

      prtree._review_gutter(gitsigns, "abc123", false)
    end)

    it("does nothing when gitsigns is not installed", function()
      prtree._review_gutter(nil, "abc123", true)
    end)
  end)

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
