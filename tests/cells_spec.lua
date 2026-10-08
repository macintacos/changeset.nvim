local cells = require("changeset.cells")

describe("changeset.cells", function()
  it("measures text in display cells", function()
    assert.equal(6, cells.width("a漢字b"))
  end)

  it("sums the widths of chunks", function()
    assert.equal(4, cells.chunks({ { "ab" }, { "漢", "Group" } }))
  end)

  describe("head", function()
    it("keeps the longest head that fits", function()
      assert.equal("a漢", cells.head("a漢字", 4))
    end)

    it("is empty when not even the first character fits", function()
      assert.equal("", cells.head("漢字", 1))
    end)

    it("keeps the longest head of a long text that fits", function()
      assert.equal(("a"):rep(9), cells.head(("a"):rep(5000) .. ("漢"):rep(5000), 9))
    end)

    it("keeps a character's composing marks with it", function()
      assert.equal("e\204\129", cells.head("e\204\129x", 1))
    end)

    it("measures a tab from the column it starts at", function()
      assert.equal("a\t", cells.head("a\tb", 8))
    end)
  end)

  describe("tail", function()
    it("keeps the longest tail that fits", function()
      assert.equal("字b", cells.tail("a漢字b", 4))
    end)

    it("keeps the longest tail of a long text that fits", function()
      assert.equal(("漢"):rep(4), cells.tail(("a"):rep(5000) .. ("漢"):rep(5000), 9))
    end)

    it("keeps a character's composing marks with it", function()
      assert.equal("e\204\129", cells.tail("xe\204\129", 1))
    end)

    it("keeps a flag whole, and within its room", function()
      assert.equal("a", cells.tail("🇺🇸🇺🇸a", 2))
    end)

    it("keeps an emoji joined into one with others whole, and within its room", function()
      local family = "👨\226\128\141👩\226\128\141👧"
      assert.equal(family .. family, cells.tail("a" .. family .. "a" .. family .. family, 4))
    end)

    it("measures a tab from the column the tail starts at", function()
      assert.equal("b", cells.tail("a\tb", 8))
    end)
  end)

  describe("clip", function()
    it("leaves text that fits", function()
      assert.equal("漢字", cells.clip("漢字", 4))
    end)

    it("cuts text that doesn't, marking the cut", function()
      assert.equal("漢…", cells.clip("漢字b", 4))
    end)

    it("is the ellipsis alone with no room", function()
      assert.equal("…", cells.clip("abc", 0))
    end)
  end)
end)
