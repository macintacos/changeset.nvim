local viewed = require("changeset.viewed")

local ROOT = "/src/app"

---@param text string
local function write_record(text)
  vim.fn.mkdir(vim.fs.dirname(viewed.path()), "p")
  vim.fn.writefile({ text }, viewed.path())
end

describe("changeset.viewed", function()
  before_each(function()
    os.remove(viewed.path())
  end)

  describe("apply", function()
    it("marks a path with its digest", function()
      assert.are.same({ [ROOT] = { ["a.lua"] = "d1" } }, viewed.apply({}, ROOT, "a.lua", "d1"))
    end)

    it("clears a mark and prunes the root it empties", function()
      local data = { [ROOT] = { ["a.lua"] = "d1" }, ["/other"] = { ["b.lua"] = "d2" } }

      assert.are.same({ ["/other"] = { ["b.lua"] = "d2" } }, viewed.apply(data, ROOT, "a.lua", nil))
    end)

    it("leaves its input unmodified", function()
      local data = { [ROOT] = { ["a.lua"] = "d1" } }

      viewed.apply(data, ROOT, "a.lua", nil)

      assert.are.same({ [ROOT] = { ["a.lua"] = "d1" } }, data)
    end)
  end)

  it("skips malformed entries in a root's marks", function()
    local data = { [ROOT] = { ["a.lua"] = "d1", ["b.lua"] = 3, [4] = "d4" } }

    assert.are.same({ ["a.lua"] = "d1" }, viewed.marks(data, ROOT))
    assert.are.same({}, viewed.marks({ [ROOT] = "x" }, ROOT))
  end)

  describe("holds", function()
    it("holds for the digest marked", function()
      assert.is_true(viewed.holds({ ["a.lua"] = "d1" }, "a.lua", "d1"))
    end)

    it("does not hold for a different digest", function()
      assert.is_false(viewed.holds({ ["a.lua"] = "d1" }, "a.lua", "d2"))
    end)

    it("does not hold for a nil digest on an unmarked path", function()
      assert.is_false(viewed.holds({}, "a.lua", nil))
    end)
  end)

  describe("toggle", function()
    it("marks, then unmarks, through the record", function()
      assert.are.same({ ["a.lua"] = "d1" }, viewed.toggle(viewed.path(), ROOT, "a.lua", "d1"))
      assert.are.same({ ["a.lua"] = "d1" }, viewed.marks(viewed.load(viewed.path()), ROOT))

      assert.are.same({}, viewed.toggle(viewed.path(), ROOT, "a.lua", "d1"))
      assert.are.same({}, viewed.load(viewed.path()))
    end)

    it("marks a path whose mark has a stale digest under the new one", function()
      viewed.toggle(viewed.path(), ROOT, "a.lua", "old")

      assert.are.same({ ["a.lua"] = "new" }, viewed.toggle(viewed.path(), ROOT, "a.lua", "new"))
    end)

    it("never writes over a record that is not a JSON object", function()
      write_record("[1,2]")

      assert.is_nil(viewed.toggle(viewed.path(), ROOT, "a.lua", "d1"))
      assert.are.same({ "[1,2]" }, vim.fn.readfile(viewed.path()))
    end)
  end)
end)
