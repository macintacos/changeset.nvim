local help = require("plugins.changeset.help")

describe("changeset.help", function()
  describe("_own", function()
    it("drops mappings another plugin put on the sidebar's buffer", function()
      local keymaps = {
        { lhs = "q", desc = "Close the tree" },
        { lhs = "]]", desc = "Next Reference" },
      }

      assert.same({ { lhs = "q", desc = "Close the tree" } }, help._own(keymaps, { "q" }))
    end)

    it("recognises its own key however the spelling differs", function()
      local keymaps = { { lhs = "<C-V>", desc = "Go to this change in a vertical split" } }

      assert.equal(1, #help._own(keymaps, { "<C-v>" }))
    end)
  end)

  describe("_stage", function()
    it("carries the keys and their descriptions onto the buffer it stages", function()
      local buf = help._stage({ { lhs = "q", desc = "Close the tree", callback = function() end } })

      local staged
      for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if keymap.lhs == "q" then
          staged = keymap
        end
      end

      assert.is_not_nil(staged)
      assert.equal("Close the tree", staged.desc)
    end)
  end)

  it("pads the keys into a column, ordered by key", function()
    local lines = help._lines({
      { lhs = "q", desc = "Close the tree" },
      { lhs = "<C-V>", desc = "Go to this change in a vertical split" },
    })

    assert.same({
      "<C-V>  Go to this change in a vertical split",
      "q      Close the tree",
    }, lines)
  end)

  it("lists only the mappings that describe themselves", function()
    local lines = help._lines({
      { lhs = "q", desc = "Close the tree" },
      { lhs = "<Plug>NetrwBrowseX", rhs = ":call netrw#BrowseX()<CR>" },
    })

    assert.same({ "q  Close the tree" }, lines)
  end)
end)
