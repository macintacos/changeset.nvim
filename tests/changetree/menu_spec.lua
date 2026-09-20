local menu = require("plugins.changetree.menu")

describe("changetree.menu", function()
  describe("_rows", function()
    it("offers no choice for a tree with no symbols in it", function()
      assert.same({}, menu._rows({}, {}))
    end)

    it("puts the noisiest kind first, which is the one worth hiding", function()
      local rows = menu._rows({ Method = 2, Variable = 31, Field = 9 }, {})

      assert.same(
        { "Variable", "Field", "Method" },
        vim.tbl_map(function(row)
          return row.kind
        end, rows)
      )
    end)

    it("names a kind the tree has even while it is hidden, so it can come back", function()
      local rows = menu._rows({ Variable = 31 }, { Variable = true })

      assert.equal(1, #rows)
      assert.is_true(rows[1].hidden)
      assert.equal(31, rows[1].count)
    end)

    it("orders kinds of equal weight by name, so the list does not shuffle", function()
      local rows = menu._rows({ Struct = 4, Class = 4 }, {})

      assert.same(
        { "Class", "Struct" },
        vim.tbl_map(function(row)
          return row.kind
        end, rows)
      )
    end)
  end)

  describe("_confirmation", function()
    it("says what is now hidden and where", function()
      assert.equal("Hiding variables and fields everywhere.", menu._confirmation({ "Variable", "Field" }, "everywhere"))
    end)

    it("says so when a save puts every kind back", function()
      assert.equal("Showing every kind on feat/login.", menu._confirmation({}, "on feat/login"))
    end)
  end)

  describe("_footer", function()
    it("names the scope a set came from", function()
      assert.equal(" set for this branch ", menu._footer({ Field = true }, { Field = true }, "branch"))
    end)

    it("warns while the working set differs from the saved one", function()
      assert.equal(" unsaved changes ", menu._footer({ Field = true }, {}, "global"))
    end)

    it("states the plain case rather than calling it unsaved", function()
      assert.equal(" showing every kind ", menu._footer({}, {}, nil))
    end)
  end)
end)
