local Fixture = require("support.git")
local Paths = require("changeset.paths")
local blocks = require("changeset.review_comment_blocks")
local comment_store = require("changeset.comment_store")
local render = require("changeset.render")
local review_comment_window = require("changeset.review_comment_window")
local unified_diff = require("changeset.unified_diff")
local window = require("changeset.window")

vim.opt.rtp:prepend(require("support.deps").path("gitsigns.nvim"))
require("gitsigns").setup()
unified_diff.activate()

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
  local dir, previous, base

  before_each(function()
    dir, previous = Fixture.enter_tempdir()
    dir = vim.fn.resolve(dir)
    Fixture.init_repo("trunk", dir)
    vim.fn.writefile(Fixture.numbered(6), "a.txt")
    base = Fixture.commit("base", dir)
    vim.fn.writefile({ "line 1", "line 3", "line 4", "changed 5", "line 6" }, "a.txt")
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
    return vim.wait(5000, function()
      return view(win) ~= nil
    end, 20)
  end

  ---@param buf integer
  ---@return boolean
  local function attached(buf)
    return vim.wait(5000, function()
      local bcache = require("gitsigns.cache").cache[buf]
      return bcache ~= nil and bcache.compare_text ~= nil
    end, 20)
  end

  it("opens the unified diff in a file opened after it starts", function()
    vim.cmd.edit("a.txt")

    assert.is_true(shows(vim.api.nvim_get_current_win()))
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

    assert.is_true(vim.wait(5000, function()
      local open = view(win)
      return open ~= nil and vim.api.nvim_buf_get_name(open.base):find(base, 1, true) ~= nil
    end, 20))
  end)

  it("keeps a conflicted file in its one window rather than gitsigns' three-way split", function()
    Fixture.commit("change", dir)
    Fixture.git({ "checkout", "-q", "-b", "other", "HEAD~1" }, dir)
    vim.fn.writefile({ "line 1", "line 2", "line 3", "line 4", "other 5", "line 6" }, "a.txt")
    Fixture.commit("other change", dir)
    vim.fn.system({ "git", "-C", dir, "merge", "-q", "trunk" })
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
    assert.is_true(vim.wait(5000, function()
      return vim.api.nvim_buf_get_name(0):find("gitsigns://", 1, true) ~= nil
    end, 20))

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
      render.define_highlights()
    end)

    after_each(function()
      vim.wo.winhighlight = ""
    end)

    ---The colours drawn at the last character of the first screen row showing `text`.
    ---@param text string
    ---@return { foreground: integer?, background: integer? }
    local function last_cell(text)
      local found
      assert.is_true(vim.wait(5000, function()
        found = screen_rows():enumerate():find(function(_, row)
          return row:find(text, 1, true) ~= nil
        end)
        return found ~= nil
      end, 20))
      local row = screen_rows():totable()[found]
      local col = vim.fn.strchars(row:sub(1, row:find(text, 1, true) + #text - 2))
      return vim.api.nvim__inspect_cell(1, found - 1, col)[2]
    end

    it("draws added and deleted lines on changeset's tints, each token in its own colour", function()
      vim.cmd.edit("a.txt")

      local deleted, added = last_cell("line 2"), last_cell("changed 5")
      assert.same(
        { vim.api.nvim_get_hl(0, { name = render.DIFF_DELETE_HL }).bg, 0xcccccc },
        { deleted.background, deleted.foreground or 0xcccccc }
      )
      assert.same(
        { vim.api.nvim_get_hl(0, { name = render.DIFF_ADD_HL }).bg, 0xcccccc },
        { added.background, added.foreground or 0xcccccc }
      )
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
    local win

    before_each(function()
      os.remove(comment_store.path())
      vim.cmd.edit("a.txt")
      win = vim.api.nvim_get_current_win()
      assert.is_true(vim.wait(5000, function()
        return screen_rows():any(function(row)
          return row:find("line 2", 1, true) ~= nil
        end)
      end, 20))
    end)

    after_each(function()
      blocks.show(false)
      os.remove(comment_store.path())
    end)

    it("opens the review comment window directly under its line, the deleted line under the window", function()
      local float = review_comment_window.open({
        line = 1,
        title = "line 1",
        save_desc = "Save",
        close_desc = "Close",
        keys = { "<C-s>" },
        save = function() end,
        keep = function() end,
        comment = { path = "a.txt", line = 1, body = "" },
      })
      vim.cmd.redraw()

      local top = vim.api.nvim_win_get_position(float)[1] + 1
      local bottom = top + vim.api.nvim_win_get_height(float) + 1
      assert.equal(vim.fn.screenpos(win, 1, 1).row, top - 1)
      assert.matches("line 2", screen_rows():totable()[bottom + 2])
      vim.api.nvim_win_close(float, true)
    end)

    it("draws a review comment's block directly under its line, the deleted line under the block", function()
      comment_store.keep(Paths.root(0), { path = "a.txt", line = 1, body = "why go?" })
      blocks.show(true)
      vim.cmd.redraw()

      local rows = screen_rows():totable()
      local line = vim.fn.screenpos(win, 1, 1).row
      assert.matches("╭ Review comment · line 1", rows[line + 1])
      assert.matches("╰", rows[line + 3])
      assert.matches("line 2", rows[line + 4])
    end)
  end)
end)
