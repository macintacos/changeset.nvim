require("support.gh")

describe("changeset.pick without mini.pick", function()
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

  it("runs where mini.pick is neither installed nor set up", function()
    assert.is_false((pcall(require, "mini.pick")))
    -- mini.nvim exposes a set-up module only as a global.
    -- selene: allow(global_usage)
    assert.is_nil(rawget(_G, "MiniPick"))
  end)

  it("loads", function()
    assert.is_true((pcall(require, "changeset.pick")))
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
    end)

    after_each(function()
      vim.o.runtimepath = rtp
      package.loaded["mini.pick"] = nil
    end)

    it("warns once that the picker needs mini.pick set up", function()
      assert.is_true((pcall(require, "mini.pick")))
      -- mini.nvim exposes a set-up module only as a global.
      -- selene: allow(global_usage)
      assert.is_nil(rawget(_G, "MiniPick"))

      require("changeset.pick").pick()

      assert.equal(1, #notes)
      assert.equal(vim.log.levels.WARN, notes[1].level)
      assert.truthy(notes[1].msg:find("mini.pick", 1, true))
      assert.truthy(notes[1].msg:find("set up", 1, true))
    end)
  end)
end)
