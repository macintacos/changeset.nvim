local Fixture = require("support.git")
local Sidebar = require("support.sidebar")
local build = require("changeset.build")
local changeset = require("changeset")
local config = require("changeset.config")
local unified_diff = require("changeset.unified_diff")
local window = require("changeset.window")
local present = require("support.present")

vim.opt.rtp:prepend(require("support.deps").path("gitsigns.nvim"))
require("gitsigns").setup()
require("support.gh")

---@type changeset.Band
local BAND = { icon = "󰢱", icon_hl = "MiniIconsAzure", path = "a.txt" }

describe("the side-by-side diff", function()
  local dir ---@type string
  local previous ---@type string

  before_each(function()
    dir, previous = Fixture.enter_tempdir()
    dir = vim.fn.resolve(dir)
    Fixture.init_repo("trunk", dir)
    vim.fn.writefile(Fixture.numbered(6), "a.txt")
    vim.fn.writefile({ "b one", "b two" }, "b.txt")
    local base = Fixture.commit("base", dir)
    Fixture.git({ "switch", "-q", "-c", "feature" }, dir)
    vim.fn.writefile({ "line 1", "line 3", "line 4", "changed 5", "line 6" }, "a.txt")
    vim.fn.writefile({ "b one", "b changed" }, "b.txt")
    vim.fn.writefile({ "added" }, "added.txt")
    Fixture.commit("change", dir)
    vim.fn.writefile({ "untracked" }, "new.txt")
    local done = false
    require("gitsigns").change_base(base, true, function()
      done = true
    end)
    assert.is_true(vim.wait(5000, function()
      return done
    end, 20))
    build.build()
    assert.is_true(vim.wait(5000, function()
      return vim.iter(present(build.current()).files):any(function(file)
        return file.path == "new.txt"
      end)
    end, 20))
    config.setup({ unified_diff = { view = "split" } })
  end)

  after_each(function()
    unified_diff.limit("none")
    window.close()
    vim.cmd("silent! only")
    vim.cmd("silent! %bwipeout!")
    require("gitsigns").change_base(nil, true)
    config.setup({})
    vim.fn.chdir(previous)
    vim.fn.delete(dir, "rf")
  end)

  ---The windows of the current tabpage in diff mode.
  ---@return integer[]
  local function diffing()
    return vim.tbl_filter(function(win)
      return vim.wo[win].diff
    end, vim.api.nvim_tabpage_list_wins(0))
  end

  ---The window in diff mode beside `win`, once there is one.
  ---@param win integer
  ---@return integer?
  local function partner(win)
    local found
    vim.wait(5000, function()
      local wins = diffing()
      if #wins == 2 and vim.list_contains(wins, win) then
        found = wins[1] == win and wins[2] or wins[1]
      end
      return found ~= nil
    end, 20)
    return found
  end

  ---@param win integer
  ---@return boolean
  local function unified(win)
    return (vim.wait(5000, function()
      return require("gitsigns.unified").get_view(win) ~= nil
    end, 20))
  end

  ---Wait for gitsigns to hold the base text of the current buffer.
  local function attached()
    local buf = vim.api.nvim_get_current_buf()
    assert.is_true(vim.wait(5000, function()
      local bcache = require("gitsigns.cache").cache[buf]
      return bcache ~= nil and bcache.compare_text ~= nil
    end, 20))
  end

  ---Whether the tabpage stays without a window in diff mode for half a second.
  ---@return boolean
  local function no_pair()
    return not vim.wait(500, function()
      return #diffing() > 0
    end, 20)
  end

  it("shows the file's base in diff mode on its left", function()
    unified_diff.turn_on()
    vim.cmd.edit("a.txt")
    local win = vim.api.nvim_get_current_win()

    local base = present(partner(win))

    assert.is_true(vim.fn.win_screenpos(base)[2] < vim.fn.win_screenpos(win)[2])
    assert.same(Fixture.numbered(6), vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(base), 0, -1, false))
    assert.is_nil(require("gitsigns.unified").get_view(win))
  end)

  it("pairs only the window being read, the rest of the tabpage unified", function()
    unified_diff.turn_on()
    vim.cmd.edit("a.txt")
    local a = vim.api.nvim_get_current_win()
    vim.cmd.split("b.txt")
    local b = vim.api.nvim_get_current_win()

    assert.is_not_nil(partner(b))
    assert.is_true(unified(a))
    assert.equal(3, #vim.api.nvim_tabpage_list_wins(0))
  end)

  it("moves the pair to the window the cursor enters", function()
    unified_diff.turn_on()
    vim.cmd.edit("a.txt")
    local a = vim.api.nvim_get_current_win()
    vim.cmd.split("b.txt")
    local b = vim.api.nvim_get_current_win()
    assert.is_not_nil(partner(b))

    vim.api.nvim_set_current_win(a)

    assert.is_not_nil(partner(a))
    assert.is_true(unified(b))
    assert.is_false(vim.wo[b].diff)
  end)

  it("moves the pair to the window a preview fills", function()
    unified_diff.turn_on()
    vim.cmd.edit("b.txt")
    local sidebar = window.open(vim.api.nvim_create_buf(false, true))
    vim.api.nvim_set_current_win(sidebar)

    window.preview(dir .. "/a.txt", 1, BAND)

    assert.is_not_nil(partner(vim.fn.bufwinid(dir .. "/a.txt")))
    assert.equal(sidebar, vim.api.nvim_get_current_win())
  end)

  it("shows a file new since the base unified, added or untracked", function()
    unified_diff.turn_on()
    for _, name in ipairs({ "added.txt", "new.txt" }) do
      vim.cmd.edit(name)

      assert.is_true(unified(vim.api.nvim_get_current_win()))
      assert.is_true(no_pair())
    end
  end)

  it("leaves the user's own unified view alone", function()
    vim.cmd.edit("a.txt")
    attached()
    vim.cmd("Gitsigns diffthis unified=true")
    assert.is_true(unified(vim.api.nvim_get_current_win()))

    unified_diff.turn_on()

    assert.is_true(no_pair())
  end)

  it("pairs nothing in a tabpage holding the user's own diff", function()
    vim.cmd.edit("a.txt")
    attached()
    vim.cmd("Gitsigns diffthis")
    assert.is_true(vim.wait(5000, function()
      return #diffing() == 2
    end, 20))

    unified_diff.turn_on()
    vim.wait(500)

    assert.equal(2, #vim.api.nvim_tabpage_list_wins(0))
    assert.equal(2, #diffing())
  end)

  it("opens nothing from the base window", function()
    unified_diff.turn_on()
    vim.cmd.edit("a.txt")
    local win = vim.api.nvim_get_current_win()
    local base = present(partner(win))

    vim.api.nvim_set_current_win(base)
    vim.wait(500)

    assert.equal(2, #vim.api.nvim_tabpage_list_wins(0))
    assert.equal(base, partner(win))
  end)

  it("opens unified while the option is unset", function()
    config.setup({})
    unified_diff.turn_on()
    vim.cmd.edit("a.txt")

    assert.is_true(unified(vim.api.nvim_get_current_win()))
    assert.is_true(no_pair())
  end)

  it("closes the base window as the diff turns off", function()
    unified_diff.turn_on()
    vim.cmd.edit("a.txt")
    local win = vim.api.nvim_get_current_win()
    assert.is_not_nil(partner(win))

    unified_diff.limit("none")

    assert.same({ win }, vim.api.nvim_tabpage_list_wins(0))
    assert.is_false(vim.wo[win].diff)
  end)

  it("takes closing the base window by hand as closing the file's diff, until turned on again", function()
    unified_diff.turn_on()
    vim.cmd.edit("a.txt")
    local win = vim.api.nvim_get_current_win()
    vim.cmd.split("b.txt")
    local other = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_close(present(partner(win)), false)

    vim.api.nvim_set_current_win(other)
    vim.api.nvim_set_current_win(win)

    assert.is_false(vim.wait(500, function()
      return vim.wo[win].diff or require("gitsigns.unified").get_view(win) ~= nil
    end, 20))

    unified_diff.turn_on()

    assert.is_not_nil(partner(win))
  end)

  it("swaps the reading window between its pair and its unified view as the view switches, both ways", function()
    unified_diff.turn_on()
    vim.cmd.edit("a.txt")
    local win = vim.api.nvim_get_current_win()
    assert.is_not_nil(partner(win))

    unified_diff.switch()

    assert.is_true(unified(win))
    assert.same({ win }, vim.api.nvim_tabpage_list_wins(0))

    unified_diff.switch()

    assert.is_not_nil(partner(win))
    assert.is_nil(require("gitsigns.unified").get_view(win))
  end)

  it("closes the pair on a file marked viewed", function()
    vim.cmd.edit("a.txt")
    local win = vim.api.nvim_get_current_win()
    changeset.open()
    assert.is_true(vim.wait(10000, function()
      return window.buf() ~= nil and Sidebar.text():find("a.txt", 1, true) ~= nil
    end, 25))
    vim.api.nvim_set_current_win(win)
    assert.is_not_nil(partner(win))

    Sidebar.cursor_to("a.txt")
    vim.api.nvim_feedkeys("x", "xt", false)
    unified_diff.refresh_viewed()

    assert.is_true(no_pair())
  end)

  describe("as windows change", function()
    ---The sidebar, open beside the window showing `name`, with the cursor in it.
    ---@param name string
    ---@return integer
    local function sidebar_beside(name)
      unified_diff.turn_on()
      vim.cmd.edit(name)
      assert.is_not_nil(partner(vim.api.nvim_get_current_win()))
      local sidebar = window.open(vim.api.nvim_create_buf(false, true))
      vim.api.nvim_set_current_win(sidebar)
      return sidebar
    end

    it("keeps the base window through a preview of another listed file, showing that file's base", function()
      sidebar_beside("a.txt")
      window.preview(dir .. "/a.txt", 1, BAND)
      local win = vim.fn.bufwinid(dir .. "/a.txt")
      local base = present(partner(win))

      window.preview(dir .. "/b.txt", 1, BAND)

      assert.is_true(vim.wait(5000, function()
        return vim.api.nvim_win_is_valid(base)
          and vim.wo[base].diff
          and vim.deep_equal(
            { "b one", "b two" },
            vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(base), 0, -1, false)
          )
      end, 20))
    end)

    it("shows the base of a previewed file once gitsigns attaches to it", function()
      sidebar_beside("a.txt")
      window.preview(dir .. "/a.txt", 1, BAND)
      local win = vim.fn.bufwinid(dir .. "/a.txt")
      assert.is_not_nil(partner(win))

      window.preview(dir .. "/b.txt", 1, BAND)

      local base = present(partner(win))
      assert.is_true(vim.wait(5000, function()
        return vim.deep_equal(
          { "b one", "b two" },
          vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(base), 0, -1, false)
        )
      end, 20))
    end)

    it("closes the base window as a preview fills its file window with an unlisted file", function()
      vim.fn.writefile({ "x" }, "unlisted.txt")
      sidebar_beside("a.txt")
      window.preview(dir .. "/a.txt", 1, BAND)
      local win = vim.fn.bufwinid(dir .. "/a.txt")
      local base = present(partner(win))

      window.preview(dir .. "/unlisted.txt", 1, BAND)

      assert.is_false(vim.api.nvim_win_is_valid(base))
      assert.is_false(vim.wo[win].diff)
    end)

    it("leaves no base window once the sidebar closes after a preview", function()
      sidebar_beside("a.txt")
      window.preview(dir .. "/a.txt", 1, BAND)
      local win = vim.fn.bufwinid(dir .. "/a.txt")
      assert.is_not_nil(partner(win))
      window.preview(dir .. "/b.txt", 1, BAND)

      changeset.close()

      assert.same({ win }, vim.api.nvim_tabpage_list_wins(0))
      assert.same({}, diffing())
    end)

    it("leaves diff mode off a file shown again after the sidebar closed", function()
      sidebar_beside("a.txt")
      window.preview(dir .. "/a.txt", 1, BAND)
      local win = vim.fn.bufwinid(dir .. "/a.txt")
      assert.is_not_nil(partner(win))
      window.preview(dir .. "/b.txt", 1, BAND)
      assert.is_not_nil(partner(win))
      changeset.close()

      vim.api.nvim_win_call(win, function()
        vim.cmd.buffer(vim.fn.bufnr(dir .. "/b.txt"))
      end)

      assert.is_false(vim.wo[win].diff)
      assert.same({ win }, vim.api.nvim_tabpage_list_wins(0))
    end)

    it("keeps the pair through a reload", function()
      unified_diff.turn_on()
      vim.cmd.edit("a.txt")
      local win = vim.api.nvim_get_current_win()
      local base = present(partner(win))

      vim.cmd("edit!")
      vim.wait(500)

      assert.is_true(vim.api.nvim_win_is_valid(base))
      assert.equal(base, partner(win))
      unified_diff.limit("none")
      assert.same({ win }, vim.api.nvim_tabpage_list_wins(0))
    end)

    it("closes the base window with its file window", function()
      unified_diff.turn_on()
      vim.cmd.edit("a.txt")
      local win = vim.api.nvim_get_current_win()
      vim.cmd.split("b.txt")
      local other = vim.api.nvim_get_current_win()
      vim.api.nvim_set_current_win(win)
      local base = present(partner(win))

      vim.api.nvim_win_close(win, false)

      assert.is_false(vim.api.nvim_win_is_valid(base))
      assert.same(
        { other },
        vim.tbl_filter(function(w)
          return w ~= present(partner(other))
        end, vim.api.nvim_tabpage_list_wins(0))
      )
    end)

    it("leaves one empty window as a lone sidebar closes after a preview", function()
      local sidebar = sidebar_beside("a.txt")
      vim.api.nvim_win_call(sidebar, function()
        vim.cmd("only")
      end)
      window.preview(dir .. "/a.txt", 1, BAND)
      assert.is_not_nil(partner(vim.fn.bufwinid(dir .. "/a.txt")))

      changeset.close()

      local wins = vim.api.nvim_tabpage_list_wins(0)
      assert.equal(1, #wins)
      assert.is_false(vim.wo[wins[1]].diff)
    end)

    it("leaves no gitsigns window behind as a session is restored", function()
      vim.cmd.runtime("plugin/changeset.lua")
      local session = vim.fn.tempname()
      changeset.open()
      assert.is_true(vim.wait(10000, function()
        return window.buf() ~= nil and Sidebar.text():find("a.txt", 1, true) ~= nil
      end, 25))
      window.preview(dir .. "/a.txt", 1, BAND)
      assert.is_not_nil(partner(vim.fn.bufwinid(dir .. "/a.txt")))
      vim.cmd("mksession! " .. vim.fn.fnameescape(session))

      vim.cmd("silent! source " .. vim.fn.fnameescape(session))
      vim.fn.delete(session)

      assert.is_false(vim.wait(1000, function()
        return vim.iter(vim.api.nvim_list_wins()):any(function(w)
          local buf = vim.api.nvim_win_get_buf(w)
          return vim.api.nvim_buf_get_name(buf):find("^gitsigns://") ~= nil
            and vim.api.nvim_buf_line_count(buf) <= 1
            and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
        end)
      end, 20))
    end)
  end)
end)
