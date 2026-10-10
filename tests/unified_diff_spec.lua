local Fixture = require("support.git")
local Paths = require("changeset.paths")
local build = require("changeset.build")
local review_comments = require("changeset.review_comments")
local comment_store = require("changeset.comment_store")
local highlights = require("changeset.highlights")
local review_comment_window = require("changeset.review_comment_window")
local unified_diff = require("changeset.unified_diff")
local window = require("changeset.window")
local present = require("support.present")

vim.opt.rtp:prepend(require("support.deps").path("gitsigns.nvim"))
require("gitsigns").setup()
require("support.gh")
unified_diff.turn_on()

---@type changeset.Band
local BAND = { icon = "󰢱", icon_hl = "MiniIconsAzure", path = "a.txt" }

---The editor's screen, a string per row, once drawn.
---@return Iter
local function screen_rows()
  vim.cmd.redraw()
  return vim.iter(vim.fn.range(1, vim.o.lines)):map(function(row)
    return table.concat(vim.tbl_map(function(col)
      return vim.fn.screenstring(row, col)
    end, vim.fn.range(1, vim.o.columns)))
  end)
end

describe("changeset.unified_diff", function()
  local dir ---@type string
  local previous ---@type string
  local base ---@type string

  before_each(function()
    dir, previous = Fixture.enter_tempdir()
    dir = vim.fn.resolve(dir)
    Fixture.init_repo("trunk", dir)
    vim.fn.writefile(Fixture.numbered(6), "a.txt")
    base = Fixture.commit("base", dir)
    Fixture.git({ "switch", "-q", "-c", "feature" }, dir)
    vim.fn.writefile({ "line 1", "line 3", "line 4", "changed 5", "line 6" }, "a.txt")
    build.build()
    assert.is_true(vim.wait(5000, function()
      return present(build.current()).collected
    end, 20))
  end)

  after_each(function()
    window.close()
    vim.cmd("silent! only")
    vim.cmd("silent! %bwipeout!")
    require("gitsigns").change_base(nil, true)
    vim.fn.chdir(previous)
    vim.fn.delete(dir, "rf")
  end)

  ---@param win integer
  ---@return Gitsigns.UnifiedView?
  local function view(win)
    return require("gitsigns.unified").get_view(win)
  end

  ---@param win integer
  ---@return boolean
  local function shows(win)
    return (vim.wait(5000, function()
      return view(win) ~= nil
    end, 20))
  end

  ---Have the tree read the diff again, until it lists `name`.
  ---@param name string
  local function listed(name)
    build.refresh()
    assert.is_true(vim.wait(5000, function()
      return vim.iter(present(build.current()).files):any(function(file)
        return file.path == name
      end)
    end, 20))
  end

  ---@param buf integer
  ---@return boolean
  local function attached(buf)
    return (
      vim.wait(5000, function()
        local bcache = require("gitsigns.cache").cache[buf]
        return bcache ~= nil and bcache.compare_text ~= nil
      end, 20)
    )
  end

  it("opens the unified diff in a file opened after it starts", function()
    vim.cmd.edit("a.txt")

    assert.is_true(shows(vim.api.nvim_get_current_win()))
  end)

  it("opens it in an untracked file, every line added", function()
    vim.fn.writefile({ "first", "second" }, "new.txt")
    listed("new.txt")

    vim.cmd.edit("new.txt")

    assert.is_true(vim.wait(5000, function()
      return (view(vim.api.nvim_get_current_win()) or {}).hunks ~= nil
    end, 20))
    assert.same(
      { { start = 1, count = 2 } },
      vim.tbl_map(function(hunk)
        return { start = hunk.added.start, count = hunk.added.count }
      end, present(present(view(vim.api.nvim_get_current_win())).hunks))
    )
  end)

  it("opens it in a split of a window already showing it", function()
    vim.cmd.edit("a.txt")
    assert.is_true(shows(vim.api.nvim_get_current_win()))

    vim.cmd("split")

    assert.is_true(shows(vim.api.nvim_get_current_win()))
  end)

  it("opens it in the window a preview fills, not the sidebar, against a base other than the index", function()
    local sha = Fixture.commit("change", dir)
    vim.fn.writefile({ "line 1", "line 3" }, "a.txt")
    Fixture.commit("change again", dir)
    local done = false
    require("gitsigns").change_base(sha, true, function()
      done = true
    end)
    assert.is_true(vim.wait(5000, function()
      return done
    end, 20))
    local sidebar = window.open(vim.api.nvim_create_buf(false, true))
    vim.api.nvim_set_current_win(sidebar)

    window.preview(dir .. "/a.txt", 1, BAND)

    local previewed = vim.fn.bufwinid(dir .. "/a.txt")
    assert.is_true(shows(previewed))
    assert.equal(sidebar, vim.api.nvim_get_current_win())
    assert.is_nil(view(sidebar))
  end)

  it("opens it in a preview of a file gitsigns already tracks, made where autocommands don't nest", function()
    local path = dir .. "/a.txt"
    vim.cmd.edit(path)
    local buf = vim.api.nvim_get_current_buf()
    -- Its view opening says gitsigns has published all it will for the file until it changes.
    assert.is_true(shows(vim.api.nvim_get_current_win()))
    vim.cmd.enew()
    local sidebar = window.open(vim.api.nvim_create_buf(false, true))
    vim.api.nvim_set_current_win(sidebar)

    -- As the sidebar previews: from its CursorMoved.
    vim.api.nvim_create_autocmd("User", {
      pattern = "UnifiedDiffSpec",
      once = true,
      callback = function()
        window.preview(path, 1, BAND)
      end,
    })
    vim.api.nvim_exec_autocmds("User", { pattern = "UnifiedDiffSpec" })

    assert.is_true(shows(vim.fn.bufwinid(buf)))
  end)

  it("opens it again once the base gitsigns compares against moves", function()
    Fixture.commit("change", dir)
    vim.cmd.edit("a.txt")
    local win = vim.api.nvim_get_current_win()
    assert.is_true(shows(win))

    require("gitsigns").change_base(base)

    assert.is_true((vim.wait(5000, function()
      local open = view(win)
      return open ~= nil and vim.api.nvim_buf_get_name(open.base):find(base, 1, true) ~= nil
    end, 20)))
  end)

  it("closes the view of a file the tree stops listing, once the tree's diff says so", function()
    vim.cmd.edit("a.txt")
    local win = vim.api.nvim_get_current_win()
    assert.is_true(shows(win))

    vim.fn.writefile(Fixture.numbered(6), "a.txt")
    vim.cmd.checktime()
    build.refresh()

    assert.is_true(vim.wait(5000, function()
      return view(win) == nil
    end, 20))
  end)

  it("closes the views of a repository once the tree is built for another", function()
    vim.cmd.edit("a.txt")
    local win = vim.api.nvim_get_current_win()
    assert.is_true(shows(win))
    local other = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(other, "p")
    Fixture.feature_one_file(other)

    vim.cmd.split(other .. "/mod.lua")
    build.build()

    assert.is_true(vim.wait(5000, function()
      local tree = present(build.current())
      return tree.root == other and tree.collected and view(win) == nil
    end, 20))
    assert.is_true(shows(vim.api.nvim_get_current_win()))
    vim.fn.delete(other, "rf")
  end)

  it("keeps a conflicted file in its one window rather than gitsigns' three-way split", function()
    Fixture.commit("change", dir)
    Fixture.git({ "checkout", "-q", "-b", "other", "HEAD~1" }, dir)
    vim.fn.writefile({ "line 1", "line 2", "line 3", "line 4", "other 5", "line 6" }, "a.txt")
    Fixture.commit("other change", dir)
    vim.fn.system({ "git", "-C", dir, "merge", "-q", "feature" })
    vim.cmd.edit("a.txt")
    local buf = vim.api.nvim_get_current_buf()
    assert.is_true(vim.wait(5000, function()
      local bcache = require("gitsigns.cache").cache[buf]
      return bcache ~= nil and bcache.git_obj.has_conflicts == true
    end, 20))

    assert.is_true(shows(vim.api.nvim_get_current_win()))
    assert.equal(1, #vim.api.nvim_tabpage_list_wins(0))
  end)

  it("leaves a revision buffer gitsigns shows alone", function()
    Fixture.commit("change", dir)
    vim.cmd.edit("a.txt")
    assert.is_true(attached(vim.api.nvim_get_current_buf()))

    require("gitsigns").show("HEAD~1")
    assert.is_true((vim.wait(5000, function()
      return vim.api.nvim_buf_get_name(0):find("gitsigns://", 1, true) ~= nil
    end, 20)))

    assert.is_false(shows(vim.api.nvim_get_current_win()))
  end)

  -- Line 2 is gone from a.txt, under line 1, and line 5 became "changed 5".
  describe("in colour", function()
    before_each(function()
      vim.o.termguicolors = true
      vim.api.nvim_set_hl(0, "Normal", { fg = 0xcccccc, bg = 0x101010 })
      -- As catppuccin's transparent theme paints them: one flat colour over every token on the line.
      vim.api.nvim_set_hl(0, "GitSignsAddPreview", { fg = 0x00ff00 })
      vim.api.nvim_set_hl(0, "GitSignsDeleteVirtLn", { fg = 0xff0000 })
      highlights.define_highlights()
    end)

    after_each(function()
      vim.wo.winhighlight = ""
      vim.wo.number = false
    end)

    ---The first screen row showing `text`, once one does.
    ---@param text string
    ---@return integer
    local function row_showing(text)
      local found ---@type integer?
      assert.is_true((vim.wait(5000, function()
        found = screen_rows():enumerate():find(function(_, row)
          return row:find(text, 1, true) ~= nil
        end)
        return found ~= nil
      end, 20)))
      return present(found)
    end

    ---The colours drawn at the last character of the first screen row showing `text`.
    ---@param text string
    ---@return { foreground: integer?, background: integer? }
    local function last_cell(text)
      local found = row_showing(text)
      local row = present(screen_rows():totable()[found]) --[[@as string]]
      local col = vim.fn.strchars(row:sub(1, present((row:find(text, 1, true))) + #text - 2))
      return vim.api.nvim__inspect_cell(1, found - 1, col)[2]
    end

    ---The text of the gutter beside screen `row`, and each background drawn in it.
    ---@param row integer
    ---@return string
    ---@return (integer|false)[]
    local function gutter(row)
      local cells = vim.tbl_map(function(col)
        return vim.api.nvim__inspect_cell(1, row - 1, col)
      end, vim.fn.range(0, present(vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]).textoff - 1))
      return table.concat(vim.tbl_map(function(cell)
        return cell[1]
      end, cells)),
        vim.list.unique(vim.tbl_map(function(cell)
          return cell[2].background or false
        end, cells))
    end

    it("draws added and deleted lines on changeset's tints, each token in its own colour", function()
      vim.cmd.edit("a.txt")

      local deleted, added = last_cell("line 2"), last_cell("changed 5")
      assert.same(
        { vim.api.nvim_get_hl(0, { name = highlights.DIFF_DELETE_HL }).bg, 0xcccccc },
        { deleted.background, deleted.foreground or 0xcccccc }
      )
      assert.same(
        { vim.api.nvim_get_hl(0, { name = highlights.DIFF_ADD_HL }).bg, 0xcccccc },
        { added.background, added.foreground or 0xcccccc }
      )
    end)

    it("hides gitsigns' signs, drawing an added line's gutter on the line's tint", function()
      vim.wo.number = true

      vim.cmd.edit("a.txt")
      row_showing("line 2")

      local added, tints = gutter(row_showing("changed 5"))
      assert.same({ "4", { vim.api.nvim_get_hl(0, { name = highlights.DIFF_ADD_HL }).bg } }, { vim.trim(added), tints })
      assert.same("1", vim.trim((gutter(row_showing("line 1")))))
    end)

    -- As a preview swaps a file back in: gitsigns signs it at once, while its view waits on its own diff.
    it("hides gitsigns' signs while the view is on its way", function()
      vim.wo.number = true
      vim.cmd.edit("a.txt")
      row_showing("line 2")
      vim.cmd.enew()

      vim.cmd.buffer("a.txt")

      local rows = screen_rows():totable()
      local row = vim.iter(ipairs(rows)):find(function(_, text)
        return text:find("changed 5", 1, true) ~= nil
      end)
      assert.is_nil((view(vim.api.nvim_get_current_win()) or {}).hunks)
      assert.same("4", vim.trim((gutter(row))))
      assert.is_true(shows(vim.api.nvim_get_current_win()))
    end)

    -- As a file loaded out of sight comes into one: gitsigns reads its base and signs it before it says so.
    it("hides gitsigns' signs before the view has started", function()
      vim.wo.number = true
      vim.cmd.edit("a.txt")
      row_showing("line 2")
      vim.cmd.enew()

      vim.cmd("noautocmd buffer a.txt")

      local rows = screen_rows():totable()
      local row = vim.iter(ipairs(rows)):find(function(_, text)
        return text:find("changed 5", 1, true) ~= nil
      end)
      assert.is_nil(view(vim.api.nvim_get_current_win()))
      assert.same("4", vim.trim((gutter(row))))
    end)

    -- gitsigns signs the lines its last hunks name as they come into sight, before it or the view diffs the edit.
    it("hides the sign gitsigns puts on a line added before either diffs it", function()
      vim.wo.number = true
      vim.cmd.edit("a.txt")
      row_showing("line 2")

      vim.api.nvim_buf_set_lines(0, 3, 3, true, { "new 5" })

      local rows = screen_rows():totable()
      local row = vim.iter(ipairs(rows)):find(function(_, text)
        return text:find("new 5", 1, true) ~= nil
      end)
      assert.same("4", vim.trim((gutter(row))))
    end)

    -- gitsigns holds a base without the file as empty text, which its view would read back as one blank line.
    it("draws every line of a file new since its base added, a blank one among them", function()
      vim.fn.writefile({ "first", "", "last" }, "new.txt")
      Fixture.commit("new", dir)
      local done = false
      require("gitsigns").change_base(base, true, function()
        done = true
      end)
      assert.is_true(vim.wait(5000, function()
        return done
      end, 20))
      -- After the base moved: the tree's read loads the file, which gitsigns would attach on the old base meanwhile.
      listed("new.txt")
      vim.wo.number = true

      vim.cmd.edit("new.txt")
      assert.is_true(vim.wait(5000, function()
        return (view(vim.api.nvim_get_current_win()) or {}).hunks ~= nil
      end, 20))

      local blank, tints = gutter(row_showing("first") + 1)
      assert.same({ "2", { vim.api.nvim_get_hl(0, { name = highlights.DIFF_ADD_HL }).bg } }, { vim.trim(blank), tints })
    end)

    it("keeps the window's own highlight overrides beside them", function()
      vim.wo.winhighlight = "Search:IncSearch"

      vim.cmd.edit("a.txt")

      assert.is_true(shows(vim.api.nvim_get_current_win()))
      assert.matches("Search:IncSearch", vim.wo.winhighlight)
    end)
  end)

  -- Line 2 is gone from a.txt, so gitsigns draws it as a virtual line under line 1.
  describe("beside review comments", function()
    local win ---@type integer?

    before_each(function()
      os.remove(comment_store.path())
      vim.cmd.edit("a.txt")
      win = vim.api.nvim_get_current_win()
      assert.is_true((vim.wait(5000, function()
        return screen_rows():any(function(row)
          return row:find("line 2", 1, true) ~= nil
        end)
      end, 20)))
    end)

    after_each(function()
      review_comments.show(false)
      os.remove(comment_store.path())
    end)

    it("opens the review comment window a blank row under its line, the deleted line under the window", function()
      local float = review_comment_window.open({
        line = 1,
        title = "line 1",
        save_desc = "Save",
        close_desc = "Close",
        keys = { "<C-s>" },
        save = function() end,
        keep = function() end,
        back = function() end,
        comment = { path = "a.txt", line = 1, body = "" },
      })
      vim.cmd.redraw()

      local top = vim.api.nvim_win_get_position(float)[1] + 1
      local bottom = top + vim.api.nvim_win_get_height(float) + 1
      assert.equal(vim.fn.screenpos(present(win), 1, 1).row, top - 2)
      assert.matches("line 2", screen_rows():totable()[bottom + 2])
      vim.api.nvim_win_close(float, true)
    end)

    it("draws a review comment's block directly under its line, the deleted line under the block", function()
      comment_store.keep(Paths.root(0), { path = "a.txt", line = 1, body = "why go?" })
      review_comments.show(true)
      vim.cmd.redraw()

      local rows = screen_rows():totable()
      local line = vim.fn.screenpos(present(win), 1, 1).row
      assert.matches("╭ Review comment · line 1", rows[line + 1])
      assert.matches("╰", rows[line + 3])
      assert.matches("line 2", rows[line + 4])
    end)
  end)

  describe("the preview bar's tint", function()
    local bar = require("changeset.preview_bar")

    it("lists the rows of its range that the view adds, 0-based", function()
      vim.cmd.edit("a.txt")
      local win = vim.api.nvim_get_current_win()
      assert.is_true(vim.wait(5000, function()
        return #((view(win) or {}).hunks or {}) > 0
      end, 20))
      local buf = vim.api.nvim_win_get_buf(win)

      -- 'changed 5' is the fourth line of a.txt.
      assert.same({ [3] = true }, unified_diff.tinted_rows(win, buf, 0, 4))
      assert.same({}, unified_diff.tinted_rows(win, buf, 0, 2))
    end)

    it("lists no rows for a buffer the view does not show", function()
      vim.cmd.edit("a.txt")
      local win = vim.api.nvim_get_current_win()
      assert.is_true(vim.wait(5000, function()
        return #((view(win) or {}).hunks or {}) > 0
      end, 20))
      local scratch = vim.api.nvim_create_buf(false, true)

      assert.same({}, unified_diff.tinted_rows(win, scratch, 0, 4))
    end)

    it("tints the bar on the rows the view adds, in the window it previews into", function()
      local sidebar = window.open(vim.api.nvim_create_buf(false, true))
      vim.api.nvim_set_current_win(sidebar)
      local span = { first = 1, last = 5, icon = "󰊕", icon_hl = "MiniIconsBlue" }

      window.preview(dir .. "/a.txt", 1, vim.tbl_extend("force", BAND, { span = span }) --[[@as changeset.Band]])

      local previewed = vim.fn.bufwinid(dir .. "/a.txt")
      assert.is_true(vim.wait(5000, function()
        return #((view(previewed) or {}).hunks or {}) > 0
      end, 20))
      vim.cmd("redraw!")
      local marks = vim.api.nvim_buf_get_extmarks(
        vim.fn.bufnr(dir .. "/a.txt"),
        bar._namespace(previewed),
        0,
        -1,
        { details = true }
      )
      assert.same(
        {
          "MiniIconsBlue",
          highlights.PREVIEW_BAR_HL,
          highlights.PREVIEW_BAR_HL,
          highlights.PREVIEW_BAR_TINT_HL,
          highlights.PREVIEW_BAR_HL,
        },
        vim.tbl_map(function(mark)
          return present(mark[4]).sign_hl_group
        end, marks)
      )
    end)
  end)
end)
