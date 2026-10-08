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
  end)

  describe("tail", function()
    it("keeps the longest tail that fits", function()
      assert.equal("字b", cells.tail("a漢字b", 4))
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
