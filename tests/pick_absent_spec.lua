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
end)
