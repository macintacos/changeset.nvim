vim.opt.rtp:prepend(require("support.deps").path("mini.pick"))
vim.opt.rtp:prepend(require("support.deps").path("mini.icons"))
require("mini.pick").setup()
require("mini.icons").setup()

local pick = require("changeset.pick")
local window = require("changeset.window")
local ns = vim.api.nvim_create_namespace("changeset.pick")
local Fixture = require("support.git")
local Notify = require("support.notify")
require("support.gh")

---Press <CR> once the picker is up, so it chooses its current item, and return what `pick()` returned.
---@return any
local function choose_current()
  local function step()
    if not MiniPick.is_picker_active() then
      return vim.defer_fn(step, 20)
    end
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "t", false)
  end
  vim.defer_fn(step, 20)
  return pick.pick()
end

---A changeset row with the fields the picker reads.
---@param fields table
---@return changeset.Row
local function row(fields)
  return vim.tbl_extend("keep", fields, { ancestor = false, children = {}, added = 1, removed = 0 })
end

---@param items table[]
---@return string[]
local function texts(items)
  return vim.tbl_map(function(item)
    return item.text
  end, items)
end

---A float holding `lines`, with a `virt_lines_above` mark on its first line.
---@param lines string[]
---@return integer win, integer buf
local function float_with_trail(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = 1,
    col = 1,
    width = 40,
    height = 6,
    style = "minimal",
  })
  vim.wo[win].wrap = false
  vim.wo[win].scrolloff = 0
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
    virt_lines = { { { "trail", "Comment" } } },
    virt_lines_above = true,
  })
  return win, buf
end

---@param win integer
---@return integer
local function topfill(win)
  return vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview().topfill
  end)
end

describe("changeset.pick", function()
  describe("_items", function()
    it("lists a changed symbol under the file and ancestors that place it", function()
      local rows = {
        row({
          kind = "file",
          path = "lua/a.lua",
          name = "lua/a.lua",
          lnum = 3,
          children = {
            row({
              kind = "symbol",
              path = "lua/a.lua",
              name = "M",
              ancestor = true,
              children = { row({ kind = "symbol", path = "lua/a.lua", name = "refresh", lnum = 12 }) },
            }),
          },
        }),
      }

      local items = pick._items(rows, "/repo")

      assert.same({ "lua/a.lua › M › refresh" }, texts(items))
      assert.equal("lua/a.lua › M", items[1].trail)
      assert.equal("/repo/lua/a.lua", items[1].path)
      assert.equal(12, items[1].lnum)
    end)

    it("lists a changed symbol and the changed symbol inside it", function()
      local inner = row({ kind = "symbol", path = "a.lua", name = "inner", lnum = 5 })
      local outer = row({ kind = "symbol", path = "a.lua", name = "outer", lnum = 4, children = { inner } })
      local rows = { row({ kind = "file", path = "a.lua", name = "a.lua", lnum = 4, children = { outer } }) }

      assert.same({ "a.lua › outer", "a.lua › outer › inner" }, texts(pick._items(rows, "/repo")))
    end)

    it("lists orphan hunks under their group, not the group itself", function()
      local orphans = row({
        kind = "orphans",
        path = "Makefile",
        name = "Other changes",
        lnum = 2,
        children = { row({ kind = "orphan", path = "Makefile", name = "L2 all: build", lnum = 2 }) },
      })
      local rows = { row({ kind = "file", path = "Makefile", name = "Makefile", lnum = 2, children = { orphans } }) }

      local items = pick._items(rows, "/repo")

      assert.same({ "Makefile › Other changes › L2 all: build" }, texts(items))
      assert.equal(2, items[1].lnum)
    end)

    it("lists a file with nothing beneath it on its own, with no trail", function()
      local items = pick._items({ row({ kind = "file", path = "a.lua", name = "a.lua", lnum = 1 }) }, "/repo")

      assert.same({ "a.lua" }, texts(items))
      assert.equal("", items[1].trail)
    end)

    it("leaves out a deleted file, which has nothing to open", function()
      local rows = { row({ kind = "file", path = "gone.lua", name = "gone.lua", status = "deleted" }) }

      assert.same({}, pick._items(rows, "/repo"))
    end)
  end)

  describe("_show", function()
    it("heads each run of items sharing a trail once, and a trail-less item not at all", function()
      local sym = row({ kind = "symbol", path = "a.lua", name = "x", symbol_kind = "Function" })
      local file = row({ kind = "file", path = "b.lua", name = "b.lua" })
      local items = {
        { text = "a.lua › x", trail = "a.lua", row = sym },
        { text = "a.lua › x", trail = "a.lua", row = sym },
        { text = "b.lua", trail = "", row = file },
      }
      local buf = vim.api.nvim_create_buf(false, true)

      pick._show(buf, items, {})

      local headed = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
        if mark[4].virt_lines then
          headed[#headed + 1] = mark[2]
        end
      end
      assert.same({ 0 }, headed)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("_reserve_trail_row", function()
    it("reserves the display row Neovim would otherwise clip the trail into, before returning", function()
      local win, buf = float_with_trail({ "one", "two", "three" })
      -- Neovim draws no filler above the topline on its own, which is exactly
      -- why a trail on the first row goes missing.
      assert.equal(0, topfill(win))

      -- Checked straight away: mini.pick draws the frame as soon as `source.show`
      -- returns, so a reservation that lands any later paints the list a row
      -- off first.
      pick._reserve_trail_row(win, true)

      assert.equal(1, topfill(win))
      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("releases the row when the first line carries no trail", function()
      local win, buf = float_with_trail({ "one", "two", "three" })
      pick._reserve_trail_row(win, true)
      pick._reserve_trail_row(win, false)

      assert.equal(0, topfill(win))
      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("does not error once the window is gone", function()
      local win, buf = float_with_trail({ "one" })
      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(buf, { force = true })

      assert.no_errors(function()
        pick._reserve_trail_row(win, true)
      end)
    end)
  end)

  describe("pick", function()
    local tmp, previous_dir

    before_each(function()
      tmp, previous_dir = Fixture.enter_tempdir()
      Fixture.init_repo("trunk", tmp)
      vim.fn.writefile({ "return 1" }, "mod.lua")
      Fixture.commit("base", tmp)
      Fixture.git({ "checkout", "-q", "-b", "feature" }, tmp)
      vim.fn.writefile({ "return 2" }, "mod.lua")
      vim.cmd.edit("mod.lua")
    end)

    after_each(function()
      require("changeset").close()
      vim.cmd("silent! %bwipeout!")
      vim.fn.chdir(previous_dir)
      vim.fn.delete(tmp, "rf")
    end)

    it("opens the changeset picker against the base branch when mini.pick is set up", function()
      local name, returned
      -- `pick()` blocks until the picker closes, so the step polls for it.
      local function step()
        if returned then
          return
        end
        if not MiniPick.is_picker_active() then
          return vim.defer_fn(step, 20)
        end
        name = MiniPick.get_picker_opts().source.name
        MiniPick.stop()
      end
      vim.defer_fn(step, 20)

      pick.pick()
      returned = true

      assert.are.equal("Changeset (vs trunk)", name)
    end)

    it("warns rather than opening the picker when there is no changeset", function()
      Fixture.git({ "checkout", "-q", "--orphan", "unrelated" }, tmp)
      Fixture.commit("unrelated", tmp)
      local notes, restore = Notify.capture()

      local ok, err = pcall(pick.pick)

      restore()
      assert(ok, err)
      assert.equal(1, #notes)
      assert.equal(vim.log.levels.WARN, notes[1].level)
    end)

    it("opens the chosen file in the window the sidebar was opened from, not in the sidebar", function()
      local from = vim.api.nvim_get_current_win()
      -- A window left of the file's, so that the file's is not the first one in the tab.
      vim.cmd("leftabove vnew")
      vim.api.nvim_set_current_win(from)
      require("changeset").open()
      local sidebar = assert(window.win())
      vim.api.nvim_set_current_win(sidebar)

      local chosen = choose_current()

      assert.equal(from, vim.api.nvim_get_current_win())
      assert.truthy(vim.endswith(vim.api.nvim_buf_get_name(0), "mod.lua"))
      assert.equal(sidebar, window.win())
      assert.equal(window.buf(), vim.api.nvim_win_get_buf(sidebar))
      assert.truthy(chosen.path:find("mod.lua", 1, true))
    end)
  end)
end)
