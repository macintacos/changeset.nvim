local changeset = require("changeset")
local build = require("changeset.build")
local draw = require("changeset.draw")
local window = require("changeset.window")
local Changes = require("support.changes")
local Fixture = require("support.git")
local Sidebar = require("support.sidebar")
local Symbols = require("support.symbols")

describe("the sidebar's redraw after a rebuild", function()
  describe("due", function()
    it("is due at once while a redraw costs a frame or less", function()
      assert.equal(1000, changeset._due(1000, 990, 10))
    end)

    it("waits twice a costlier redraw's cost after it ended", function()
      assert.equal(580, changeset._due(500, 500, 40))
    end)

    it("stays due then however early the next rebuild comes", function()
      assert.equal(580, changeset._due(530, 500, 40))
    end)

    it("is due at once once that wait has passed", function()
      assert.equal(700, changeset._due(700, 500, 40))
    end)
  end)

  describe("over a tree that draws slowly", function()
    local tmp, previous_dir, source, real_draw, draws

    before_each(function()
      tmp, previous_dir = Fixture.enter_tempdir()
      Fixture.feature({
        ["a.lua"] = { "return 1" },
        ["b.lua"] = { "return 1" },
        ["c.lua"] = { "return 1" },
      }, {
        ["a.lua"] = { "return 2" },
        ["b.lua"] = { "return 2" },
        ["c.lua"] = { "return 2" },
      }, tmp)
      source = Symbols.install()
      vim.cmd.edit("a.lua")
      local opening = vim.uv.hrtime()
      changeset.open()
      assert.is_true(vim.wait(10000, function()
        return #source.asks == 1 and window.buf() ~= nil and Sidebar.text():find("c.lua", 1, true) ~= nil
      end, 10))
      -- On a slow machine the opening draw costs over a frame, which would hold back the first
      -- answer's: it cost at most this long, and twice its cost is the longest it holds one back.
      vim.wait(math.ceil(2 * (vim.uv.hrtime() - opening) / 1e6))
      real_draw, draws = draw.draw, 0
      draw.draw = function(...)
        draws = draws + 1
        real_draw(...)
        -- Past a frame, and long enough that a refresh's diff lands before the wait runs out.
        vim.uv.sleep(150)
      end
    end)

    after_each(function()
      draw.draw = real_draw
      source.restore()
      changeset.close()
      vim.cmd("silent! %bwipeout!")
      vim.fn.chdir(previous_dir)
      vim.fn.delete(tmp, "rf")
    end)

    ---@param path string
    local function answer(path)
      source.answer(path, { Changes.sym("f_" .. path:sub(1, 1), "Function", 0, 1, 1) })
    end

    it("draws the answers that arrive while it waits together, once the wait is over", function()
      answer("a.lua")
      answer("b.lua")
      answer("c.lua")

      assert.equal(1, draws)
      assert.is_nil(Sidebar.text():find("f_b", 1, true))
      assert.is_true(vim.wait(2000, function()
        return Sidebar.text():find("f_c", 1, true) ~= nil
      end, 10))
      assert.equal(2, draws)
      assert.truthy(Sidebar.text():find("f_b", 1, true))
    end)

    it("draws at once when a new diff lands while it waits", function()
      answer("a.lua")
      answer("b.lua")
      local before = build.current().files

      build.refresh()
      assert.is_true(vim.wait(2000, function()
        return build.current().files ~= before
      end, 1))

      assert.equal(2, draws)
      assert.truthy(Sidebar.text():find("f_b", 1, true))
      vim.wait(400)
      assert.equal(2, draws)
    end)

    it("draws once, at once, when something else redraws while it waits", function()
      answer("a.lua")
      answer("b.lua")

      vim.api.nvim_exec_autocmds("VimResized", {})

      assert.equal(2, draws)
      assert.truthy(Sidebar.text():find("f_b", 1, true))
      vim.wait(400)
      assert.equal(2, draws)
    end)

    it("still settles once the wait is over after a sidebar key drew the tree meanwhile", function()
      answer("a.lua")
      answer("b.lua")
      vim.api.nvim_set_current_win((assert(window.win())))

      vim.cmd.normal("L")

      assert.equal(2, draws)
      assert.is_true(vim.wait(2000, function()
        return draws == 3
      end, 10))
    end)

    it("steps over the rows of answers whose draw still waits", function()
      answer("a.lua")
      answer("b.lua")

      changeset.step(1, "symbol")

      assert.equal("b.lua", vim.fs.basename(vim.api.nvim_buf_get_name(0)))
    end)

    it("keeps following you deeper after a return to the sidebar's tabpage settles a waiting draw", function()
      vim.cmd.edit("c.lua")
      Sidebar.flush()
      changeset.toggle()
      answer("b.lua")
      vim.cmd.tabnew("c.lua")
      answer("c.lua")
      vim.cmd.tabprevious()
      assert.truthy(Sidebar.cursor_line():find("f_c", 1, true))

      local asked = #source.asks
      local buf = vim.fn.bufnr("c.lua")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local a = 1", "local b = 2", "return 3" })
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent write")
      end)
      assert.is_true(vim.wait(2000, function()
        return #source.asks > asked
      end, 10))
      source.answer("c.lua", {
        Changes.sym("K", "Class", 0, 1, 3),
        Changes.sym("m1", "Method", 1, 1, 1),
        Changes.sym("m2", "Method", 1, 2, 3),
      })
      assert.is_true(vim.wait(2000, function()
        return Sidebar.text():find("m2", 1, true) ~= nil
      end, 10))

      assert.truthy(Sidebar.cursor_line():find("m1", 1, true))
    end)

    it("lists the rows of every answer while their draw waits", function()
      answer("a.lua")
      answer("b.lua")

      local tree = assert(changeset.rows())

      local names = vim.tbl_map(function(row)
        return (row.children[1] or {}).name
      end, tree.rows)
      assert.same({ "f_a", "f_b" }, vim.list_slice(names, 1, 2))
    end)
  end)
end)
