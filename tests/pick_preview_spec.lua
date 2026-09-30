vim.opt.rtp:prepend(require("support.deps").path("mini.pick"))
require("mini.pick").setup()

local preview = require("changeset.pick_preview")
preview.setup()

---Every float except the picker's own window.
---@return integer[]
local function side_floats()
  local state = MiniPick.get_picker_state()
  local main = state and state.windows.main
  return vim.tbl_filter(function(win)
    return win ~= main and vim.api.nvim_win_get_config(win).relative ~= ""
  end, vim.api.nvim_list_wins())
end

---Start a picker and run `steps` against it in turn, then stop it.
---
---`MiniPick.start` blocks until the picker stops, so each step is a timer the
---picker's key loop runs while it waits for input — spaced out so the previous
---step's keys have been handled by the time the next one looks.
---@param opts table Options for `MiniPick.start`.
---@param steps fun()[]
local function drive(opts, steps)
  local i = 0
  local function step()
    i = i + 1
    if steps[i] then
      steps[i]()
      vim.defer_fn(step, 50)
    else
      MiniPick.stop()
    end
  end
  vim.defer_fn(step, 50)
  MiniPick.start(opts)
end

---Write a file of numbered lines, e.g. "a1", "a2", …
---@param dir string
---@param name string
---@param n integer
---@return string path
local function numbered_file(dir, name, n)
  local lines = {}
  for i = 1, n do
    lines[i] = name .. i
  end
  local path = vim.fs.joinpath(dir, name .. ".txt")
  vim.fn.writefile(lines, path)
  return path
end

describe("changeset.pick_preview", function()
  describe("_layout", function()
    it("gives a narrow editor's whole width to the list, with no preview", function()
      assert.same({ list = preview.MIN_COLUMNS - 1 }, preview._layout(preview.MIN_COLUMNS - 1))
    end)

    it("splits a wide editor so both floats and their borders fill it", function()
      local layout = preview._layout(200)
      assert.is_true(layout.list < layout.preview)
      assert.equal(200, layout.list + layout.preview + 4)
    end)
  end)

  describe("_float_config", function()
    it("sits right of the list's border, level with it", function()
      local list = { anchor = "SW", row = 40, col = 0, width = 80, height = 24, border = "single", zindex = 251 }
      local config = preview._float_config(list, 116)
      assert.equal(82, config.col)
      assert.equal(116, config.width)
      assert.equal(40, config.row)
      assert.equal(24, config.height)
      assert.equal("SW", config.anchor)
    end)
  end)

  describe("in a running picker", function()
    local dir, columns

    before_each(function()
      dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      columns = vim.o.columns
      vim.o.columns = 200
    end)

    after_each(function()
      vim.o.columns = columns
      vim.fn.delete(dir, "rf")
    end)

    it("follows the current item as it moves", function()
      local a, b = numbered_file(dir, "a", 3), numbered_file(dir, "b", 3)
      local seen = {}
      drive({ source = { items = { a, b } }, window = preview.window() }, {
        function()
          local floats = side_floats()
          seen.count = #floats
          seen.first = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(floats[1]), 0, 1, false)[1]
          vim.api.nvim_input("<C-n>")
        end,
        function()
          local floats = side_floats()
          seen.second = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(floats[1]), 0, 1, false)[1]
        end,
      })

      assert.equal(1, seen.count)
      assert.equal("a1", seen.first)
      assert.equal("b1", seen.second)
    end)

    it("closes the preview when the picker stops", function()
      local opened
      drive({ source = { items = { numbered_file(dir, "e", 1) } }, window = preview.window() }, {
        function()
          opened = #side_floats()
        end,
      })

      assert.equal(1, opened)
      assert.same({}, side_floats())
    end)

    it("puts the cursor on an item's line", function()
      local path = numbered_file(dir, "c", 200)
      local line
      drive({ source = { items = { { text = "c", path = path, lnum = 120 } } }, window = preview.window() }, {
        function()
          line = vim.api.nvim_win_get_cursor(side_floats()[1])[1]
        end,
      })

      assert.equal(120, line)
    end)

    it("leaves pickers that did not opt in alone", function()
      local count
      drive({ source = { items = { numbered_file(dir, "d", 1) } } }, {
        function()
          count = #side_floats()
        end,
      })

      assert.equal(0, count)
    end)

    it("shows no preview in an editor too narrow for one", function()
      vim.o.columns = preview.MIN_COLUMNS - 1
      local count
      drive({ source = { items = { numbered_file(dir, "e", 1) } }, window = preview.window() }, {
        function()
          count = #side_floats()
        end,
      })

      assert.equal(0, count)
    end)
  end)
end)
