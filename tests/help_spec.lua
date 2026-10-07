local help = require("changeset.help")

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

      assert.not_nil(staged)
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

  describe("show without which-key", function()
    after_each(function()
      vim.cmd("silent! fclose!")
    end)

    it("lists every key in a float of its own, from a float too short for them, keeping focus", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local own = {}
      for i = 1, 12 do
        local lhs = "<F" .. i .. ">"
        vim.keymap.set("n", lhs, "<Nop>", { buffer = buf, desc = "key " .. i })
        own[i] = lhs
      end
      local win = vim.api.nvim_open_win(buf, true, { relative = "editor", row = 1, col = 1, width = 40, height = 6 })

      help.show(buf, own)

      local shown = vim.iter(vim.api.nvim_list_wins()):find(function(each)
        return each ~= win and vim.api.nvim_win_get_config(each).relative ~= ""
      end)
      assert.equal(win, vim.api.nvim_get_current_win())
      assert.truthy(shown)
      assert.equal(12, vim.api.nvim_win_get_height(shown))
    end)
  end)
end)
