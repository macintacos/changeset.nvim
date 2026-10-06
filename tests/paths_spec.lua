local Paths = require("changeset.paths")

describe("changeset.paths", function()
  describe("copy", function()
    local has, notify, notes

    before_each(function()
      has, notify, notes = vim.fn.has, vim.notify, {}
      vim.notify = function(msg)
        table.insert(notes, msg)
      end
      vim.fn.has = function(feature)
        return feature == "clipboard" and 0 or has(feature)
      end
    end)

    after_each(function()
      vim.fn.has, vim.notify = has, notify
    end)

    it("copies to the unnamed register without a clipboard, and names it", function()
      vim.fn.setreg('"', "")

      Paths.copy("a.lua:4", "relative path:line")

      assert.equal("a.lua:4", vim.fn.getreg('"'))
      assert.truthy(notes[1]:find('"', 1, true))
    end)
  end)
end)
