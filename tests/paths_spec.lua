local Paths = require("changeset.paths")
local Notify = require("support.notify")

describe("changeset.paths", function()
  describe("copy", function()
    local has, restore_notify, notes

    before_each(function()
      has = vim.fn.has
      notes, restore_notify = Notify.capture()
      vim.fn.has = function(feature)
        return feature == "clipboard" and 0 or has(feature)
      end
    end)

    after_each(function()
      vim.fn.has = has
      restore_notify()
    end)

    it("copies to the unnamed register without a clipboard, and names it", function()
      vim.fn.setreg('"', "")

      Paths.copy("a.lua:4", "relative path:line")

      assert.equal("a.lua:4", vim.fn.getreg('"'))
      assert.truthy(notes[1].msg:find('"', 1, true))
    end)
  end)
end)
