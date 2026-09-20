local window = require("plugins.changetree.window")

---A `usable` predicate that accepts only the listed windows.
---@param ok integer[]
---@return fun(win: integer): boolean
local function only(ok)
  return function(win)
    return vim.tbl_contains(ok, win)
  end
end

describe("changetree.window", function()
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

  describe("_candidates", function()
    it("offers the window with focus first, then the one focused before it", function()
      assert.same({ 7, 9, 3 }, window._candidates(7, 9, { 3, 7, 9 }))
    end)

    it("leaves out a previous window that is no longer there", function()
      assert.same({ 7, 3, 9 }, window._candidates(7, 0, { 3, 7, 9 }))
    end)
  end)

  describe("_pick_target", function()
    it("takes the first window that can hold a file", function()
      assert.equal(7, window._pick_target({ 7, 3 }, only({ 7, 3 })))
    end)

    it("skips candidates holding a special buffer", function()
      assert.equal(9, window._pick_target({ 7, 3, 9 }, only({ 9 })))
    end)

    it("asks for a new split when no window can hold a preview", function()
      assert.is_nil(window._pick_target({ 3, 9 }, only({})))
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
      vim.api.nvim_buf_set_name(stale, "changetree://tree")
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

  describe("previewing", function()
    local files

    before_each(function()
      files = {}
      vim.cmd("only")
    end)

    after_each(function()
      window.close()
      vim.cmd("only")
      for _, path in ipairs(files) do
        vim.fn.delete(path)
      end
    end)

    ---@return string path
    local function fixture(text)
      local path = vim.fn.tempname()
      vim.fn.writefile({ text, text, text }, path)
      files[#files + 1] = path
      return path
    end

    ---The file a window is showing. Resolved, since opening a file by a path
    ---under a symlinked $TMPDIR names the buffer by its real location.
    ---@param win integer
    ---@return string
    local function showing(win)
      return vim.fn.resolve(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)))
    end

    ---Two side-by-side windows, focus in the right one, sidebar open.
    ---@return integer left, integer right, string shown_left, string shown_right
    local function staged()
      local one, two = fixture("one"), fixture("two")
      vim.cmd("edit " .. one)
      local left = vim.api.nvim_get_current_win()
      vim.cmd("vsplit " .. two)
      local right = vim.api.nvim_get_current_win()
      window.open(vim.api.nvim_create_buf(false, true))
      return left, right, one, two
    end

    it("follows the window the user moved to", function()
      local left, right, one, two = staged()
      window.preview(one, 2)

      vim.api.nvim_set_current_win(left)
      window.focus()
      window.preview(two, 3)

      assert.equal(vim.fn.resolve(two), showing(left))
      assert.equal(vim.fn.resolve(one), showing(right))
    end)

    it("marks the window a preview lands in", function()
      local _, right, one = staged()

      window.preview(one, 2)

      assert.is_true(vim.wo[right].winbar:find(vim.fn.fnamemodify(one, ":."), 1, true) ~= nil)
    end)

    -- Previewing the file the window already shows, which is where the mark
    -- would otherwise outlive the sidebar: Neovim puts window options back with
    -- the buffer they belonged to, and here the buffer never changes.
    it("gives a borrowed window back the winbar it had", function()
      local _, right, _, two = staged()
      vim.wo[right].winbar = "mine"

      window.preview(two, 2)
      window.close()

      assert.equal("mine", vim.wo[right].winbar)
    end)

    it("gives back the winbar even when the buffer it displaced is gone", function()
      local _, right, one = staged()
      local displaced = vim.api.nvim_win_get_buf(right)
      vim.wo[right].winbar = "mine"

      window.preview(one, 2)
      vim.api.nvim_buf_delete(displaced, { force = true })
      window.close()

      assert.equal("mine", vim.wo[right].winbar)
    end)

    it("takes the mark off the window a commit claims", function()
      local _, right, one = staged()
      window.preview(one, 2)
      window.focus()

      window.commit(one, 2, "reuse")

      assert.equal("", vim.wo[right].winbar)
    end)

    it("puts back every window it previewed into", function()
      local left, right, one, two = staged()
      window.preview(one, 2)
      vim.api.nvim_set_current_win(left)
      window.focus()
      window.preview(two, 3)

      window.close()

      assert.equal(vim.fn.resolve(one), showing(left))
      assert.equal(vim.fn.resolve(two), showing(right))
    end)
  end)
end)
