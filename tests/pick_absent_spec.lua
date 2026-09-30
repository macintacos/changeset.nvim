require("support.gh")

describe("changeset.pick without mini.pick", function()
  assert(not pcall(require, "mini.pick") and MiniPick == nil, "mini.pick must be neither installed nor set up")

  local notify, notes

  before_each(function()
    notify, notes = vim.notify, {}
    vim.notify = function(msg, level)
      table.insert(notes, { msg = msg, level = level })
    end
  end)

  after_each(function()
    vim.notify = notify
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
