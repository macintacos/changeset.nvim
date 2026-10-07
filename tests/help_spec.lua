local help = require("changeset.help")

describe("changeset.help", function()
  describe("_own", function()
    it("tells the sidebar's mappings from those another plugin put on its buffer", function()
      local keymaps = {
        { lhs = "q", desc = "Close the tree" },
        { lhs = "]]", desc = "Next Reference" },
      }

      local mine, others = help._own(keymaps, { "q" })
      assert.same({ { lhs = "q", desc = "Close the tree" } }, mine)
      assert.same({ { lhs = "]]", desc = "Next Reference" } }, others)
    end)

    it("recognises its own key however the spelling differs", function()
      local keymaps = { { lhs = "<C-V>", desc = "Go to this change in a vertical split" } }

      assert.equal(1, #help._own(keymaps, { "<C-v>" }))
    end)
  end)

  describe("show with which-key", function()
    after_each(function()
      package.loaded["which-key"] = nil
    end)

    it("gives the buffer another plugin's mappings back as they were", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(buf)
      vim.keymap.set("n", "q", "<Nop>", { buffer = buf, desc = "Close the tree" })
      vim.keymap.set("n", ",a", function() end, { buffer = buf, desc = "Callback" })
      vim.keymap.set("n", ",e", function()
        return "<Nop>"
      end, { buffer = buf, expr = true, desc = "Expr" })
      vim.keymap.set("n", ",n", "<Nop>", { buffer = buf, nowait = true, silent = true, desc = "Nowait" })
      local function maps()
        local keymaps = vim.api.nvim_buf_get_keymap(buf, "n")
        table.sort(keymaps, function(a, b)
          return a.lhs < b.lhs
        end)
        return keymaps
      end
      local before = maps()
      package.loaded["which-key"] = { show = function() end }

      help.show(buf, { "q" })

      assert.same(before, maps())
    end)

    it("shows over a buffer that goes while which-key is up", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(buf)
      vim.keymap.set("n", "]]", "<Nop>", { buffer = buf, desc = "Next Reference" })
      package.loaded["which-key"] = {
        show = function()
          vim.api.nvim_buf_delete(buf, { force = true })
        end,
      }

      help.show(buf, {})
    end)

    it("gives the buffer another plugin's mappings back when which-key fails", function()
      local buf = vim.api.nvim_get_current_buf()
      vim.keymap.set("n", "q", "<Nop>", { buffer = buf, desc = "Close the tree" })
      vim.keymap.set("n", "]]", "<Nop>", { buffer = buf, desc = "Next Reference" })
      package.loaded["which-key"] = {
        show = function()
          error("popup failed", 0)
        end,
      }

      assert.has_error(function()
        help.show(buf, { "q" })
      end, "popup failed")
      local lhs = vim.tbl_map(function(keymap)
        return keymap.lhs
      end, vim.api.nvim_buf_get_keymap(buf, "n"))
      table.sort(lhs)
      assert.same({ "]]", "q" }, lhs)
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
