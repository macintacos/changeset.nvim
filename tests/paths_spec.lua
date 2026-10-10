local Paths = require("changeset.paths")
local Notify = require("support.notify")
local present = require("support.present")

describe("changeset.paths", function()
  describe("copy", function()
    local has
    local restore_notify ---@type fun()
    local notes ---@type support.notify.Note[]

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
      assert.truthy((present(notes[1]).msg:find('"', 1, true)))
    end)
  end)

  describe("relative", function()
    it("gives a file under the root its path from the root", function()
      assert.equal("lua/a.lua", Paths.relative("/repo", "/repo/lua/a.lua"))
    end)

    it("gives nil for a file outside the root", function()
      assert.is_nil(Paths.relative("/repo", "/elsewhere/a.lua"))
    end)

    it("gives nil for an unnamed buffer", function()
      assert.is_nil(Paths.relative("/repo", ""))
    end)
  end)
end)
