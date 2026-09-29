local window = require("changeset.window")

---What the band says is the sidebar's business; these tests only need one to pass on.
---@type changeset.Band
local BAND = { icon = "󰢱", icon_hl = "MiniIconsAzure", path = "src/session.ts" }

---A `usable` predicate that accepts only the listed windows.
---@param ok integer[]
---@return fun(win: integer): boolean
local function only(ok)
  return function(win)
    return vim.tbl_contains(ok, win)
  end
end

---The edge of the editor `win` runs the whole length of, if any.
---@param win integer
---@return "bottom"|"right"|nil
local function edge(win)
  local layout = vim.fn.winlayout()
  local last = layout[2][#layout[2]]
  if last[1] ~= "leaf" or last[2] ~= win then
    return nil
  end
  return ({ col = "bottom", row = "right" })[layout[1]]
end

describe("changeset.window", function()
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

  describe("_centred", function()
    it("puts the text on the middle row, padded to the middle column", function()
      local lines, row = window._centred("gone", 10, 5)

      assert.equal(2, row)
      assert.equal("   gone", lines[row + 1])
    end)

    it("does not pad text wider than the window", function()
      local lines, row = window._centred("a long message", 4, 1)

      assert.equal("a long message", lines[row + 1])
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

  describe("_reveal_cursor", function()
    local buf, win

    before_each(function()
      buf = vim.api.nvim_create_buf(false, true)
      local lines = {}
      for i = 1, 200 do
        lines[i] = "line " .. i
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      win = vim.api.nvim_open_win(buf, true, { relative = "editor", row = 0, col = 0, width = 40, height = 20 })
      vim.wo[win].scrolloff = 0
      vim.wo[win].foldmethod = "manual"
    end)

    after_each(function()
      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    ---Reveal line `lnum` of the 20-line window.
    ---@param lnum integer
    ---@return integer[] view The window's top line and the cursor's screen row.
    local function reveal(lnum)
      vim.api.nvim_win_set_cursor(win, { lnum, 0 })
      window._reveal_cursor()
      return { vim.fn.line("w0"), vim.fn.winline() }
    end

    it("puts the cursor line 30% down the window", function()
      assert.same({ 95, 6 }, reveal(100))
    end)

    it("counts a closed fold above the cursor as one screen line", function()
      vim.cmd("90,98fold")

      assert.same({ 87, 6 }, reveal(100))
    end)

    it("keeps 'scrolloff' lines above the cursor when 30% is fewer", function()
      vim.wo[win].scrolloff = 8

      assert.same({ 92, 9 }, reveal(100))
    end)

    it("stops at the top of the buffer", function()
      assert.same({ 1, 3 }, reveal(3))
    end)

    it("scrolls without feeding keys, which on_key listeners would take for typing", function()
      local ns = vim.api.nvim_create_namespace("windows_spec")
      local keys = {}
      vim.on_key(function(key)
        table.insert(keys, key)
      end, ns)

      reveal(100)
      vim.on_key(nil, ns)

      assert.same({}, keys)
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
      require("changeset.config").setup()
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
      vim.api.nvim_buf_set_name(stale, "changeset://tree")
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

    it("opens along the bottom when the editor is too narrow to stand it beside the files", function()
      vim.o.columns = 100
      vim.cmd("vsplit")

      local win = window.open(vim.api.nvim_create_buf(false, true))

      assert.equal("bottom", edge(win))
    end)

    it("opens along the bottom below a raised layout.min_file_width", function()
      vim.o.columns = 200
      require("changeset.config").setup({ layout = { min_file_width = 160 } })
      vim.cmd("vsplit")

      assert.equal("bottom", edge(window.open(vim.api.nvim_create_buf(false, true))))
    end)

    it("stands beside the files above a lowered layout.min_file_width", function()
      vim.o.columns = 120
      require("changeset.config").setup({ layout = { min_file_width = 60 } })
      vim.cmd("vsplit")

      assert.equal("right", edge(window.open(vim.api.nvim_create_buf(false, true))))
    end)

    it("moves along the bottom when the editor narrows, keeping its window", function()
      vim.cmd("vsplit")
      local win = window.open(vim.api.nvim_create_buf(false, true))

      vim.o.columns = 100
      window.relayout()

      assert.equal(win, window.win())
      assert.equal("bottom", edge(win))
    end)

    it("moves back beside the files at its own width when the editor widens", function()
      vim.o.columns = 100
      vim.cmd("vsplit")
      local win = window.open(vim.api.nvim_create_buf(false, true))

      vim.o.columns = 200
      window.relayout()

      assert.equal("right", edge(win))
      assert.equal(44, vim.api.nvim_win_get_width(win))
      local widths = others()
      assert.is_true(widths[2] - widths[1] <= 1)
    end)

    it("stays put as the only window when the editor narrows", function()
      local outside = vim.api.nvim_get_current_win()
      window.open(vim.api.nvim_create_buf(false, true))
      vim.api.nvim_win_close(outside, true)

      vim.o.columns = 100

      assert.no_errors(window.relayout)
    end)

    it("comes back along the bottom from a session saved beside the files, when the editor is narrow", function()
      local stale = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(stale, "changeset://tree")
      local placeholder = vim.api.nvim_open_win(stale, false, { split = "right", win = -1, width = 44 })
      vim.o.columns = 100

      window.open(vim.api.nvim_create_buf(false, true))

      assert.equal("bottom", edge(placeholder))
    end)
  end)

  describe("what it reports about itself", function()
    after_each(function()
      window.close()
      vim.cmd("only")
    end)

    it("reports no window once the one it opened is closed by hand", function()
      window.open(vim.api.nvim_create_buf(false, true))
      vim.api.nvim_win_close(assert(window.win()), true)

      assert.is_nil(window.win())
      assert.is_false(window.is_visible())
    end)

    it("reports nothing visible from a tabpage the sidebar is not in", function()
      window.open(vim.api.nvim_create_buf(false, true))
      vim.cmd("tabnew")
      local visible = window.is_visible()
      vim.cmd("tabclose")

      assert.is_false(visible)
    end)

    it("hands its window an ordinary buffer when nothing is left to fall back to", function()
      vim.cmd("only")
      local outside = vim.api.nvim_get_current_win()
      local tree = vim.api.nvim_create_buf(false, true)
      local win = window.open(tree)
      vim.api.nvim_win_close(outside, true)

      window.close()

      assert.is_true(vim.api.nvim_win_is_valid(win))
      assert.not_equal(tree, vim.api.nvim_win_get_buf(win))
    end)
  end)

  describe("previewing", function()
    local files

    before_each(function()
      files = {}
      vim.cmd("only")
    end)

    after_each(function()
      -- `tabfirst` first: a failure that strands focus in the new tab would
      -- otherwise leave `tabonly` closing the one the sidebar is in.
      vim.cmd("silent! tabfirst")
      vim.cmd("silent! tabonly")
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
      window.preview(one, 2, BAND)

      vim.api.nvim_set_current_win(left)
      window.focus()
      window.preview(two, 3, BAND)

      assert.equal(vim.fn.resolve(two), showing(left))
      assert.equal(vim.fn.resolve(one), showing(right))
    end)

    it("marks the window a preview lands in with the path the sidebar named", function()
      local _, right, one = staged()
      window.focus()

      window.preview(one, 2, BAND)

      assert.is_true(vim.wo[right].winbar:find(BAND.path, 1, true) ~= nil)
    end)

    -- Previewing the file the window already shows, which is where the mark
    -- would otherwise outlive the sidebar: Neovim puts window options back with
    -- the buffer they belonged to, and here the buffer never changes.
    it("gives a borrowed window back the winbar it had", function()
      local _, right, _, two = staged()
      vim.wo[right].winbar = "mine"

      window.preview(two, 2, BAND)
      window.close()

      assert.equal("mine", vim.wo[right].winbar)
    end)

    it("gives back the winbar even when the buffer it displaced is gone", function()
      local _, right, one = staged()
      local displaced = vim.api.nvim_win_get_buf(right)
      vim.wo[right].winbar = "mine"

      window.preview(one, 2, BAND)
      vim.api.nvim_buf_delete(displaced, { force = true })
      window.close()

      assert.equal("mine", vim.wo[right].winbar)
    end)

    it("takes the mark off the window a commit claims", function()
      local _, right, one = staged()
      window.preview(one, 2, BAND)
      window.focus()

      window.commit(one, 2, "reuse")

      assert.equal("", vim.wo[right].winbar)
    end)

    -- Previewing the file the window already shows: a buffer round trip restores
    -- the cursor on its own, so only a preview that never changes the buffer can
    -- tell whether the sidebar put the position back itself.
    it("gives a borrowed window back the cursor it had", function()
      local _, right, _, two = staged()
      vim.api.nvim_win_set_cursor(right, { 3, 0 })

      window.preview(two, 1, BAND)
      window.close()

      assert.same({ 3, 0 }, vim.api.nvim_win_get_cursor(right))
    end)

    it("opens a new tabpage for a commit that asks for one", function()
      local _, _, one = staged()
      local before = #vim.api.nvim_list_tabpages()

      window.commit(one, 2, "tab")

      assert.equal(before + 1, #vim.api.nvim_list_tabpages())
    end)

    -- Only `tab` can leak: `:tabnew` records the position it is standing on and
    -- lands on an empty buffer, whereas `split`/`vsplit` copy the jumplist across
    -- instead of adding to it.
    it("sends <C-o> from a new tab back to where the window stood, not the preview", function()
      local _, right, one, two = staged()
      local stood_lnum = vim.api.nvim_win_get_cursor(right)[1]
      local stood_buf = vim.api.nvim_win_get_buf(right)
      window.preview(two, 2, BAND)

      window.commit(one, 2, "tab")

      local jumps = vim.fn.getjumplist()[1]
      local lnums = {}
      for _, jump in ipairs(jumps) do
        if jump.bufnr == stood_buf then
          lnums[#lnums + 1] = jump.lnum
        end
      end
      assert.same({ stood_lnum }, lnums)
      assert.equal(stood_buf, jumps[#jumps].bufnr)
    end)

    -- A file the sidebar opened by itself, never `:edit`ed, so `bufadd` left it
    -- unlisted and the commit is the only thing that can promote it.
    it("lists the buffer a commit claims", function()
      staged()
      local three = fixture("three")

      window.commit(three, 2, "reuse")

      assert.is_true(vim.bo[vim.api.nvim_get_current_buf()].buflisted)
    end)

    -- Scrolling an unfocused window drags its cursor without focusing it, so a
    -- claim that re-revealed the cursor would jump the view as focus arrived.
    it("keeps the view of a preview the cursor moves into", function()
      local _, right = staged()
      local tall = vim.fn.tempname()
      vim.fn.writefile(vim.tbl_map(tostring, vim.fn.range(1, 300)), tall)
      files[#files + 1] = tall
      window.focus()
      window.preview(tall, 150, BAND)
      vim.api.nvim_win_call(right, function()
        vim.cmd("normal! 40" .. vim.keycode("<C-e>"))
      end)
      local scrolled = vim.api.nvim_win_call(right, vim.fn.winsaveview)

      vim.api.nvim_set_current_win(right)
      window.claim()

      local view = vim.fn.winsaveview()
      assert.equal(scrolled.topline, view.topline)
      assert.equal(scrolled.lnum, view.lnum)
    end)

    it("puts a borrowed window back without disturbing its jumplist", function()
      local _, right, one = staged()
      local before = vim.fn.getjumplist(right)[1]

      window.preview(one, 2, BAND)
      window.close()

      assert.same(before, vim.fn.getjumplist(right)[1])
    end)

    it("shows a notice as read-only text the buffer list never sees", function()
      local _, right = staged()
      window.focus()

      window.preview_notice("This file was deleted", BAND)

      local buf = vim.api.nvim_win_get_buf(right)
      assert.is_false(vim.bo[buf].buflisted)
      assert.is_false(vim.bo[buf].modifiable)
      assert.truthy(
        table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("This file was deleted", 1, true)
      )
      assert.is_true(vim.wo[right].winbar:find(BAND.path, 1, true) ~= nil)
    end)

    it("keeps one notice highlight however often the notice is shown", function()
      local _, right = staged()

      window.preview_notice("This file was deleted", BAND)
      window.preview_notice("This file was deleted", BAND)

      local buf = vim.api.nvim_win_get_buf(right)
      local ns = vim.api.nvim_get_namespaces()["changeset.notice"]
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
      assert.equal(1, #marks)
      assert.truthy(
        vim.api.nvim_buf_get_lines(buf, marks[1][2], marks[1][2] + 1, false)[1]:find("This file was deleted", 1, true)
      )
    end)

    it("previews a file into the window a notice is standing in", function()
      local _, right, one = staged()
      window.preview_notice("This file was deleted", BAND)
      local before = #vim.api.nvim_tabpage_list_wins(0)

      window.preview(one, 2, BAND)

      assert.equal(before, #vim.api.nvim_tabpage_list_wins(0))
      assert.equal(vim.fn.resolve(one), showing(right))
    end)

    it("leaves a notice borrowed when the cursor moves into it", function()
      local _, right, _, two = staged()
      window.focus()
      window.preview_notice("This file was deleted", BAND)
      local notice = vim.api.nvim_win_get_buf(right)

      vim.api.nvim_set_current_win(right)
      window.claim()

      assert.equal(notice, vim.api.nvim_win_get_buf(right))
      assert.is_false(vim.bo[notice].buflisted)
      window.close()
      assert.equal(vim.fn.resolve(two), showing(right))
    end)

    it("puts a borrowed window back after showing a notice in it", function()
      local _, right, _, two = staged()
      vim.wo[right].winbar = "mine"

      window.preview_notice("This file was deleted", BAND)
      window.close()

      assert.equal(vim.fn.resolve(two), showing(right))
      assert.equal("mine", vim.wo[right].winbar)
    end)

    it("gives a file a window above the drawer when the drawer is the only one", function()
      local columns = vim.o.columns
      vim.o.columns = 100
      local outside = vim.api.nvim_get_current_win()
      local win = window.open(vim.api.nvim_create_buf(false, true))
      vim.api.nvim_win_close(outside, true)

      window.preview(fixture("one"), 1, BAND)
      vim.o.columns = columns

      assert.equal("bottom", edge(win))
    end)

    it("puts back every window it previewed into", function()
      local left, right, one, two = staged()
      window.preview(one, 2, BAND)
      vim.api.nvim_set_current_win(left)
      window.focus()
      window.preview(two, 3, BAND)

      window.close()

      assert.equal(vim.fn.resolve(one), showing(left))
      assert.equal(vim.fn.resolve(two), showing(right))
    end)
  end)
end)
