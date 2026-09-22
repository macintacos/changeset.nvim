local menu = require("plugins.changeset.menu")

local ROOT = "/fixture/repo"
local BRANCH = "feature"

local function write_json(path, data)
  local file = assert(io.open(path, "w"))
  file:write(vim.json.encode(data))
  file:close()
end

local function read_json(path)
  local file = assert(io.open(path, "r"))
  local data = file:read("*a")
  file:close()
  return vim.json.decode(data)
end

local function read_bytes(path)
  local file = assert(io.open(path, "rb"))
  local data = file:read("*a")
  file:close()
  return data
end

describe("changeset.menu", function()
  describe("_rows", function()
    it("offers no choice for a tree with no symbols in it", function()
      assert.same({}, menu._rows({}, {}))
    end)

    it("puts the noisiest kind first, which is the one worth hiding", function()
      local rows = menu._rows({ Method = 2, Variable = 31, Field = 9 }, {})

      assert.same(
        { "Variable", "Field", "Method" },
        vim.tbl_map(function(row)
          return row.kind
        end, rows)
      )
    end)

    it("names a kind the tree has even while it is hidden, so it can come back", function()
      local rows = menu._rows({ Variable = 31 }, { Variable = true })

      assert.equal(1, #rows)
      assert.is_true(rows[1].hidden)
      assert.equal(31, rows[1].count)
    end)

    it("orders kinds of equal weight by name, so the list does not shuffle", function()
      local rows = menu._rows({ Struct = 4, Class = 4 }, {})

      assert.same(
        { "Class", "Struct" },
        vim.tbl_map(function(row)
          return row.kind
        end, rows)
      )
    end)
  end)

  describe("_footer", function()
    it("names the scope a set came from", function()
      assert.equal(" set for this branch ", menu._footer({ Field = true }, { Field = true }, "branch"))
    end)

    it("warns while the working set differs from the saved one", function()
      assert.equal(" unsaved changes ", menu._footer({ Field = true }, {}, "global"))
    end)

    it("states the plain case rather than calling it unsaved", function()
      assert.equal(" showing every kind ", menu._footer({}, {}, nil))
    end)
  end)

  describe("mappings", function()
    local tmp, preferences_file, sidebar, sidebar_buf, reported_hidden

    local function mapping_callback(lhs)
      local mapping = vim.fn.maparg(lhs, "n", false, true)
      assert.equal("function", type(mapping.callback))
      return mapping.callback
    end

    local function open_menu(saved_preferences, overrides)
      write_json(preferences_file, saved_preferences)
      reported_hidden = nil
      menu.open(vim.tbl_extend("force", {
        root = ROOT,
        branch = BRANCH,
        file = preferences_file,
        counts = { Field = 2, Method = 11, Variable = 31 },
        hidden = {},
        icon = function()
          return "K", "Special"
        end,
        sidebar = sidebar,
        on_change = function(hidden)
          reported_hidden = hidden
        end,
      }, overrides or {}))
      return vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    end

    before_each(function()
      tmp = vim.fn.tempname()
      vim.fn.mkdir(tmp, "p")
      preferences_file = tmp .. "/filters.json"

      sidebar_buf = vim.api.nvim_create_buf(false, true)
      sidebar = vim.api.nvim_open_win(sidebar_buf, false, {
        relative = "editor",
        row = 1,
        col = 30,
        width = 44,
        height = 8,
        style = "minimal",
        border = "rounded",
      })
    end)

    after_each(function()
      menu.close()
      if sidebar and vim.api.nvim_win_is_valid(sidebar) then
        vim.api.nvim_win_close(sidebar, true)
      end
      if sidebar_buf and vim.api.nvim_buf_is_valid(sidebar_buf) then
        vim.api.nvim_buf_delete(sidebar_buf, { force = true })
      end
      vim.fn.delete(tmp, "rf")
    end)

    it("toggles the focused row and reports the new hidden set", function()
      local buf = open_menu({}, { counts = { Variable = 31 } })
      local before = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]

      mapping_callback("x")()

      local after = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
      assert.equal("▎ K Variable", before:gsub("%s+31$", ""))
      assert.equal("  K Variable", after:gsub("%s+31$", ""))
      assert.same({ Variable = true }, reported_hidden)
    end)

    it("saves the hidden set globally", function()
      open_menu({}, { hidden = { Field = true, Variable = true } })

      mapping_callback("<CR>")()

      assert.same({ global = { "Field", "Variable" } }, read_json(preferences_file))
    end)

    it("saves the hidden set for the repository", function()
      open_menu({}, { hidden = { Field = true, Variable = true } })

      mapping_callback("r")()

      assert.same({ repos = { [ROOT] = { kinds = { "Field", "Variable" } } } }, read_json(preferences_file))
    end)

    it("saves the hidden set for the branch", function()
      open_menu({}, { hidden = { Field = true, Variable = true } })

      mapping_callback("b")()

      assert.same({
        repos = { [ROOT] = { branches = { [BRANCH] = { "Field", "Variable" } } } },
      }, read_json(preferences_file))
    end)

    for _, lhs in ipairs({ "q", "<Esc>" }) do
      it(("restores the saved set and leaves the file unchanged on %s"):format(lhs), function()
        open_menu({ global = { "Variable" } }, { counts = { Variable = 31 }, hidden = { Variable = true } })
        local before = read_bytes(preferences_file)

        mapping_callback("x")()
        assert.same({}, reported_hidden)

        mapping_callback(lhs)()

        assert.same({ Variable = true }, reported_hidden)
        assert.equal(before, read_bytes(preferences_file))
      end)
    end

    it("docks the float at the sidebar's available-room boundary", function()
      local _, menu_win = open_menu({}, { counts = { Variable = 31 } })
      local sidebar_left = vim.api.nvim_win_get_position(sidebar)[2]
      local width = vim.api.nvim_win_get_width(menu_win)
      local config = vim.api.nvim_win_get_config(menu_win)

      assert.equal(sidebar_left - 2, width)
      assert.equal(sidebar_left, config.col + width + 1)
    end)
  end)
end)
