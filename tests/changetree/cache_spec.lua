local cache = require("plugins.changetree.cache")

---@param path string
---@param added integer?
---@return changetree.File
local function file(path, added)
  return { path = path, status = "modified", added = added or 1, removed = 0, hunks = {} }
end

---A stamp function answering from a table, as `fresh` would read the disk.
---@param map table<string, string>
---@return fun(path: string): string?
local function stamps(map)
  return function(path)
    return map[path]
  end
end

describe("changetree.cache", function()
  describe("fresh", function()
    it("keeps the symbols of a file that has not changed since they were read", function()
      local entries = { ["api.ts"] = { stamp = "120:9", symbols = { { name = "send" } } } }

      local known, unknown = cache.fresh(entries, { file("api.ts") }, stamps({ ["api.ts"] = "120:9" }))

      assert.same({ ["api.ts"] = { { name = "send" } } }, known)
      assert.same({}, unknown)
    end)

    it("asks again for a file that has changed since", function()
      local entries = { ["api.ts"] = { stamp = "120:9", symbols = { { name = "send" } } } }

      local known, unknown = cache.fresh(entries, { file("api.ts") }, stamps({ ["api.ts"] = "340:11" }))

      assert.same({}, known)
      assert.equal(1, #unknown)
      assert.equal("api.ts", unknown[1].path)
    end)

    it("asks about a file it has never read", function()
      local known, unknown = cache.fresh({}, { file("api.ts") }, stamps({ ["api.ts"] = "120:9" }))

      assert.same({}, known)
      assert.equal(1, #unknown)
    end)

    it("asks again for a file it can no longer stamp", function()
      local entries = { ["gone.ts"] = { stamp = "120:9", symbols = {} } }

      local known, unknown = cache.fresh(entries, { file("gone.ts") }, stamps({}))

      assert.same({}, known)
      assert.equal(1, #unknown)
    end)
  end)

  describe("project", function()
    it("keeps only the fields the tree reads", function()
      local projected = cache.project({
        {
          name = "send",
          kind = "Function",
          depth = 1,
          lnum = 12,
          range_lnum = 12,
          range_end_lnum = 30,
          text = "send",
          path = "api.ts",
          col = 6,
          end_col = 10,
          end_lnum = 12,
          guides = { "│", "├" },
          crumb = "Client",
        },
      })

      assert.same({
        { name = "send", kind = "Function", depth = 1, lnum = 12, range_lnum = 12, range_end_lnum = 30 },
      }, projected)
    end)
  end)

  describe("the file on disk", function()
    local path

    before_each(function()
      path = vim.fn.tempname() .. ".json"
    end)

    after_each(function()
      vim.fn.delete(path)
    end)

    it("reads back what it wrote", function()
      local entries = { ["api.ts"] = { stamp = "120:9", symbols = { { name = "send", lnum = 12 } } } }

      cache.save(path, entries)

      assert.same(entries, cache.load(path))
    end)

    it("starts empty when nothing has been written yet", function()
      assert.same({}, cache.load(path))
    end)

    it("starts empty rather than failing on a corrupt file", function()
      vim.fn.writefile({ "{ not json" }, path)

      assert.same({}, cache.load(path))
    end)
  end)

  describe("stamp", function()
    it("changes when the file does", function()
      local path = vim.fn.tempname()
      vim.fn.writefile({ "one" }, path)
      local before = cache.stamp(path)

      vim.fn.writefile({ "one", "two" }, path)

      assert.is_string(before)
      assert.not_equal(before, cache.stamp(path))
      vim.fn.delete(path)
    end)

    it("has no stamp for a file that is not there", function()
      assert.is_nil(cache.stamp(vim.fn.tempname()))
    end)
  end)
end)
