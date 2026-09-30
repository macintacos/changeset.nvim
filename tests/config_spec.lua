describe("changeset.config", function()
  local config = require("changeset.config")

  after_each(function()
    config.setup()
  end)

  it("lays each setup() over the defaults, not over the last one", function()
    config.setup({ keymaps = { jump = "o" } })
    config.setup({ layout = { min_file_width = 100 } })
    assert.equal("<CR>", config.get().keymaps.jump)
    assert.equal(100, config.get().layout.min_file_width)
  end)

  it("rejects a bad value, naming the option, and keeps the options in force", function()
    config.setup({ layout = { min_file_width = 100 } })
    for _, case in ipairs({
      { { keymaps = { jump = true } }, "keymaps.jump" },
      { { keymaps = { jump = "" } }, "keymaps.jump" },
      { { layout = { min_file_width = "80" } }, "layout.min_file_width" },
      { { pr_review = { enabled = "yes" } }, "pr_review.enabled" },
      { { keymaps = false }, "keymaps" },
    }) do
      local ok, err = pcall(config.setup, case[1])
      assert.is_false(ok)
      assert.is_string(err)
      assert.truthy(string.find(tostring(err), case[2], 1, true), err)
    end
    assert.equal(100, config.get().layout.min_file_width)
  end)
end)
