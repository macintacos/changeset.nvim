local window = require("plugins.prtree.window")

---A `usable` predicate that accepts only the listed windows.
---@param ok integer[]
---@return fun(win: integer): boolean
local function only(ok)
  return function(win)
    return vim.tbl_contains(ok, win)
  end
end

describe("prtree.window", function()
  describe("_clamp", function()
    it("keeps a line that is already inside the buffer", function()
      assert.equal(12, window._clamp(12, 40))
    end)

    it("pulls a line past the end back to the last one", function()
      assert.equal(40, window._clamp(88, 40))
    end)

    it("never lands on line zero when the buffer reports no lines", function()
      assert.equal(1, window._clamp(1, 0))
    end)

    it("never lands on line zero for a deletion hunk reported at the top of a file", function()
      assert.equal(1, window._clamp(0, 40))
    end)
  end)

  describe("_pick_target", function()
    it("keeps previewing into the window pinned at open", function()
      assert.equal(7, window._pick_target(7, { 3, 7 }, only({ 3, 7 })))
    end)

    it("falls back to the most recent usable window once the pinned one is gone", function()
      assert.equal(3, window._pick_target(7, { 3, 9 }, only({ 3, 9 })))
    end)

    it("skips candidates holding a special buffer", function()
      assert.equal(9, window._pick_target(7, { 3, 9 }, only({ 9 })))
    end)

    it("asks for a new split when no window can hold a preview", function()
      assert.is_nil(window._pick_target(7, { 3, 9 }, only({})))
    end)
  end)

  describe("open", function()
    local columns

    before_each(function()
      columns = vim.o.columns
      vim.o.columns = 200
      vim.cmd("only")
    end)

    after_each(function()
      window.close()
      vim.cmd("only")
      vim.o.columns = columns
    end)

    ---Widths of every window the sidebar does not occupy.
    ---@return integer[]
    local function others()
      local out = {}
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if win ~= window.win() then
          out[#out + 1] = vim.api.nvim_win_get_width(win)
        end
      end
      table.sort(out)
      return out
    end

    it("takes its width out of the layout and leaves the other windows even", function()
      vim.cmd("vsplit")
      vim.cmd("vsplit")

      local win = window.open(vim.api.nvim_create_buf(false, true))

      assert.equal(44, vim.api.nvim_win_get_width(win))
      local widths = others()
      assert.equal(3, #widths)
      assert.is_true(widths[3] - widths[1] <= 1)
    end)

    it("takes over the window a restored session left, instead of opening another", function()
      local stale = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(stale, "prtree://tree")
      local placeholder = vim.api.nvim_open_win(stale, false, { split = "right", win = -1, width = 44 })
      local before = #vim.api.nvim_tabpage_list_wins(0)
      local buf = vim.api.nvim_create_buf(false, true)

      window.open(buf)

      assert.equal(before, #vim.api.nvim_tabpage_list_wins(0))
      assert.equal(placeholder, window.win())
      assert.equal(buf, vim.api.nvim_win_get_buf(placeholder))
    end)

    it("does not take the sidebar it just opened for a leftover", function()
      window.open(vim.api.nvim_create_buf(false, true))

      assert.is_nil(window.placeholder())
    end)
  end)
end)
