local cache = require("changeset.cache")

---@param path string
---@param added integer?
---@return changeset.File
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

describe("changeset.cache", function()
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

    it("asks again about a file whose entry is not a record of symbols", function()
      local entries = { ["a.ts"] = 5, ["b.ts"] = vim.NIL, ["c.ts"] = { stamp = "120:9", symbols = 5 } }
      local files = { file("a.ts"), file("b.ts"), file("c.ts") }

      local known, unknown =
        cache.fresh(entries, files, stamps({ ["a.ts"] = "120:9", ["b.ts"] = "120:9", ["c.ts"] = "120:9" }))

      assert.same({}, known)
      assert.equal(3, #unknown)
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
    it("keeps the fields the tree reads", function()
      local projected = cache.project({
        { name = "send", kind = "Function", depth = 1, lnum = 12, range_lnum = 12, range_end_lnum = 30 },
      })

      assert.same({
        { name = "send", kind = "Function", depth = 1, lnum = 12, range_lnum = 12, range_end_lnum = 30 },
      }, projected)
    end)

    it("keeps the test flag the syntax gave a symbol", function()
      local projected = cache.project({
        { name = "load", kind = "Function", depth = 0, lnum = 1, range_lnum = 1, range_end_lnum = 3, test = true },
      })

      assert.is_true(projected[1].test)
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

    it("leaves out what no server answered, which only this Neovim remembers", function()
      local entries = {
        ["api.ts"] = { stamp = "120:9", symbols = { { name = "send", lnum = 12 } } },
        ["go.sum"] = { stamp = "80:3", symbols = {}, silent = true },
      }
      cache.save(path, entries)

      assert.same({ "api.ts" }, vim.tbl_keys(cache.load(path)))
    end)

    it("reads back the entries it saved", function()
      local entries = {
        ["api.ts"] = { stamp = "120:9", symbols = { { name = "send", lnum = 12 } } },
        ["db.ts"] = { stamp = "80:3", symbols = {}, comments = { new = { comment = { { 1, 2 } } } } },
      }
      cache.encode(entries["api.ts"])

      cache.save(path, entries)

      assert.same(entries, cache.load(path))
    end)

    it("saves the entry filed in place of another", function()
      local entries = { ["api.ts"] = { stamp = "120:9", symbols = { { name = "send" } } } }
      cache.save(path, entries)

      entries["api.ts"] = { stamp = "121:9", symbols = { { name = "receive" } } }
      cache.save(path, entries)

      assert.same(entries, cache.load(path))
    end)

    it("encodes an entry once, however often it is saved", function()
      local entries = { ["api.ts"] = { stamp = "120:9", symbols = { { name = "send" } } } }
      cache.encode(entries["api.ts"])
      local real_encode, encoded = vim.json.encode, 0
      vim.json.encode = function(value, ...)
        encoded = encoded + (type(value) == "table" and 1 or 0)
        return real_encode(value, ...)
      end

      local ok, err = pcall(function()
        cache.save(path, entries)
        cache.save(path, entries)
      end)
      vim.json.encode = real_encode

      assert(ok, err)
      assert.equal(0, encoded)
    end)
  end)

  describe("path", function()
    it("names the file for the entry format it holds", function()
      assert.truthy(vim.endswith(cache.path("/repo"), ".v5.json"))
    end)
  end)

  describe("stamp", function()
    it("changes when the file does", function()
      local path = vim.fn.tempname()
      vim.fn.writefile({ "one" }, path)
      local before = cache.stamp(path, "base")

      vim.fn.writefile({ "one", "two" }, path)

      assert.is_string(before)
      assert.not_equal(before, cache.stamp(path, "base"))
      vim.fn.delete(path)
    end)

    it("changes when the file is rewritten at the same size", function()
      local path = vim.fn.tempname()
      vim.fn.writefile({ "one" }, path)
      assert(vim.uv.fs_utime(path, 1000, 1000))
      local before = cache.stamp(path, "base")

      vim.fn.writefile({ "two" }, path)
      assert(vim.uv.fs_utime(path, 2000, 2000))

      assert.is_string(before)
      assert.not_equal(before, cache.stamp(path, "base"))
      vim.fn.delete(path)
    end)

    it("changes when the base does", function()
      local path = vim.fn.tempname()
      vim.fn.writefile({ "one" }, path)

      assert.not_equal(cache.stamp(path, "abc123"), cache.stamp(path, "def456"))
      vim.fn.delete(path)
    end)

    it("has no stamp for a file that is not there", function()
      assert.is_nil(cache.stamp(vim.fn.tempname(), "base"))
    end)
  end)
end)
