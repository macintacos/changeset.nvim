local resolve = require("plugins.changeset.resolve")

describe("changeset.resolve", function()
  describe("_resolvable", function()
    it("keeps files in the order they are displayed, so the tree fills top-down", function()
      local files = {
        { path = "api.ts", status = "modified" },
        { path = "auth.ts", status = "added" },
      }

      assert.same({ "api.ts", "auth.ts" }, resolve._resolvable(files))
    end)

    it("skips a deleted file, which has no content left to read symbols from", function()
      local files = {
        { path = "gone.ts", status = "deleted" },
        { path = "auth.ts", status = "modified" },
      }

      assert.same({ "auth.ts" }, resolve._resolvable(files))
    end)
  end)
end)
