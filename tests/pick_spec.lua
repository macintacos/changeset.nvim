vim.opt.rtp:prepend(require("support.deps").path("mini.pick"))
vim.opt.rtp:prepend(require("support.deps").path("mini.icons"))
require("mini.pick").setup()
require("mini.icons").setup()

local changeset = require("changeset.pick")

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

      local items = changeset._items(rows, "/repo")

      assert.same({ "lua/a.lua › M › refresh" }, texts(items))
      assert.equal("lua/a.lua › M", items[1].trail)
      assert.equal("/repo/lua/a.lua", items[1].path)
      assert.equal(12, items[1].lnum)
    end)

    it("lists a changed symbol and the changed symbol inside it", function()
      local inner = row({ kind = "symbol", path = "a.lua", name = "inner", lnum = 5 })
      local outer = row({ kind = "symbol", path = "a.lua", name = "outer", lnum = 4, children = { inner } })
      local rows = { row({ kind = "file", path = "a.lua", name = "a.lua", lnum = 4, children = { outer } }) }

      assert.same({ "a.lua › outer", "a.lua › outer › inner" }, texts(changeset._items(rows, "/repo")))
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

      local items = changeset._items(rows, "/repo")

      assert.same({ "Makefile › Other changes › L2 all: build" }, texts(items))
      assert.equal(2, items[1].lnum)
    end)

    it("lists a file with nothing beneath it on its own, with no trail", function()
      local items = changeset._items({ row({ kind = "file", path = "a.lua", name = "a.lua", lnum = 1 }) }, "/repo")

      assert.same({ "a.lua" }, texts(items))
      assert.equal("", items[1].trail)
    end)

    it("leaves out a deleted file, which has nothing to open", function()
      local rows = { row({ kind = "file", path = "gone.lua", name = "gone.lua", status = "deleted" }) }

      assert.same({}, changeset._items(rows, "/repo"))
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

      changeset._show(buf, items, {})

      local headed = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, changeset.ns, 0, -1, { details = true })) do
        if mark[4].virt_lines then
          headed[#headed + 1] = mark[2]
        end
      end
      assert.same({ 0 }, headed)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)
end)
