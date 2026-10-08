require("support.gh")
local Notify = require("support.notify")

describe("changeset.pick without mini.pick", function()
  assert(not pcall(require, "mini.pick") and MiniPick == nil, "mini.pick must be neither installed nor set up")

  local notes, restore

  before_each(function()
    notes, restore = Notify.capture()
  end)

  after_each(function()
    restore()
  end)

  it("warns once that the picker needs mini.pick", function()
    require("changeset.pick").pick()

    assert.equal(1, #notes)
    assert.equal(vim.log.levels.WARN, notes[1].level)
    assert.truthy(notes[1].msg:find("mini.pick", 1, true))
  end)

  describe("installed but not set up", function()
    local rtp

    before_each(function()
      rtp = vim.o.runtimepath
      vim.opt.runtimepath:prepend(require("support.deps").path("mini.pick"))
      assert(pcall(require, "mini.pick") and MiniPick == nil, "mini.pick must be installed but not set up")
    end)

    after_each(function()
      vim.o.runtimepath = rtp
      package.loaded["mini.pick"] = nil
    end)

    it("warns once that the picker needs mini.pick set up", function()
      require("changeset.pick").pick()

      assert.equal(1, #notes)
      assert.equal(vim.log.levels.WARN, notes[1].level)
      assert.truthy(notes[1].msg:find("mini.pick", 1, true))
      assert.truthy(notes[1].msg:find("set up", 1, true))
    end)
  end)
end)
