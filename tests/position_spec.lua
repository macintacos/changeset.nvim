local position = require("changeset.position")
local Rows = require("changeset.rows")
local Changes = require("support.changes")

local FILES = { Changes.file("mod.lua", { 5, 15, 30 }), Changes.file("other.lua", { 3 }) }
-- `Store` holds the changed `load`, `Storefront` beside it changed too, and line 30 is in no symbol.
local SYMBOLS = {
  Changes.sym("Store", "Class", 0, 1, 10),
  Changes.sym("load", "Method", 1, 3, 8),
  Changes.sym("Storefront", "Class", 0, 12, 20),
}

-- Every row on screen:
--  1 Implementation   4 load              7 L30                10 L3
--  2 mod.lua          5 Storefront        8 other.lua
--  3 Store            6 Other changes     9 Other changes
local ROWS = Rows.build(FILES, { ["mod.lua"] = SYMBOLS, ["other.lua"] = {} })
-- Before mod.lua's symbols are in: 1 Implementation, 2 mod.lua, 3 other.lua, 4 Other changes, 5 L3.
local READING = Rows.build(FILES, { ["other.lua"] = {} })

local RS = "src/session.rs"
-- A file shown in two sections: 1 Implementation, 2 session.rs, 3 load, 4 Tests, 5 session.rs, 6 tests, 7 refreshes.
local SPLIT = Rows.build({ Changes.file(RS, { 1, 4 }) }, {
  [RS] = {
    Changes.sym("load", "Function", 0, 1, 1),
    Changes.sym("tests", "Module", 0, 3, 6),
    Changes.sym("refreshes", "Function", 1, 4, 5),
  },
})

local MOD = "#implementation\0mod.lua"
local STORE = MOD .. "\0Store"
local LOAD = STORE .. "\0load"
local STOREFRONT = MOD .. "\0Storefront"
local MOD_ORPHANS = MOD .. "\0#orphans"
local OTHER = "#implementation\0other.lua"
local OTHER_ORPHANS = OTHER .. "\0#orphans"

---The rows a sidebar shows, in display order, with nothing under the rows `folded` names.
---@param rows changeset.Row[]
---@param folded table<string, true>?
---@param out changeset.Row[]?
---@return changeset.Row[]
local function shown(rows, folded, out)
  out = out or {}
  for _, row in ipairs(rows) do
    out[#out + 1] = row
    if not (folded or {})[row.id] then
      shown(row.children, folded, out)
    end
  end
  return out
end

---The sidebar as the shell hands it over: every row shown, the cursor on line 1 and focus elsewhere unless told.
---@param rows changeset.Row[]
---@param opts { visible: changeset.Row[]?, cursor: integer?, focused: boolean? }?
---@return changeset.position.View
local function view(rows, opts)
  opts = opts or {}
  return {
    rows = rows,
    visible = opts.visible or shown(rows),
    cursor = opts.cursor or 1,
    focused = opts.focused or false,
  }
end

---@param id string
---@return changeset.Row
local function row(id)
  return assert(Rows.find(ROWS, id), id)
end

local function decided()
  return true
end

local function reading()
  return false
end

describe("changeset.position", function()
  describe("marks", function()
    it("marks the row for where you are", function()
      local p = position.new()

      p:track({ path = "mod.lua", lnum = 5 })

      assert.same({ { kind = "here", lnum = 4 } }, p:marks(view(ROWS)))
    end)

    it("marks where you are on the deepest row on screen when yours is folded away", function()
      local p = position.new()
      p:track({ path = "mod.lua", lnum = 5 })

      local marks = p:marks(view(ROWS, { visible = shown(ROWS, { [STORE] = true }) }))

      assert.same({ { kind = "here", lnum = 3 } }, marks)
    end)

    it(
      "marks where you are on the file, not a sibling whose name starts the same, when a filter hides yours",
      function()
        local p = position.new()
        p:track({ path = "mod.lua", lnum = 15 })
        local filtered = vim.tbl_filter(function(shown_row)
          return shown_row.id ~= STOREFRONT
        end, shown(ROWS))

        assert.same({ { kind = "here", lnum = 2 } }, p:marks(view(ROWS, { visible = filtered })))
      end
    )

    it("marks nothing for where you are when a filter hides your row's whole section", function()
      local p = position.new()
      p:track({ path = RS, lnum = 4 })
      local implementation_only = vim.list_slice(shown(SPLIT), 1, 3)

      assert.same({}, p:marks(view(SPLIT, { visible = implementation_only })))
    end)

    it("marks nothing for where you are in a file the changeset does not hold", function()
      local p = position.new()

      p:track({ path = "plain.lua", lnum = 1 })

      assert.same({}, p:marks(view(ROWS)))
    end)

    it("marks the selected row only while the sidebar has focus", function()
      local p = position.new()

      assert.same({ { kind = "selected", lnum = 8 } }, p:marks(view(ROWS, { cursor = 8, focused = true })))
      assert.same({}, p:marks(view(ROWS, { cursor = 8 })))
    end)

    it("marks only the selection on a line it shares with where you are", function()
      local p = position.new()
      p:track({ path = "mod.lua", lnum = 5 })

      assert.same({ { kind = "selected", lnum = 4 } }, p:marks(view(ROWS, { cursor = 4, focused = true })))
    end)

    it("marks only where you are on a line it shares with the pick", function()
      local p = position.new()
      p:pick(row(LOAD))

      p:track({ path = "mod.lua", lnum = 5 })

      assert.same({ { kind = "here", lnum = 4 } }, p:marks(view(ROWS)))
    end)

    it("keeps the pick on its row as you move elsewhere", function()
      local p = position.new()
      p:pick(row(LOAD))

      p:track({ path = "other.lua", lnum = 3 })

      assert.same({ { kind = "here", lnum = 9 }, { kind = "picked", lnum = 4 } }, p:marks(view(ROWS)))
    end)

    it("marks a picked chain on the symbol it jumps to once the chain is opened out", function()
      local compressed = Rows.compress(ROWS, function()
        return false
      end)
      local chain = assert(Rows.find(compressed, STORE))
      local p = position.new()

      p:pick(chain)

      assert.same({ { kind = "picked", lnum = 4 } }, p:marks(view(ROWS)))
    end)

    it("marks a hidden pick on its group when the group is the deepest row shown", function()
      local p = position.new()
      p:pick(row(MOD_ORPHANS .. "\0#orphan:30"))

      local marks = p:marks(view(ROWS, { visible = shown(ROWS, { [MOD_ORPHANS] = true }) }))

      assert.same({ { kind = "picked", lnum = 6 } }, marks)
    end)

    it("finds a pick the rows no longer hold again from its file and line", function()
      local p = position.new()
      p:pick(row(LOAD))
      -- `load` is gone, and `Store` itself changed: 1 Implementation, 2 mod.lua, 3 Store.
      local rebuilt =
        Rows.build(FILES, { ["mod.lua"] = { Changes.sym("Store", "Class", 0, 1, 10) }, ["other.lua"] = {} })

      assert.same({ { kind = "picked", lnum = 3 } }, p:marks(view(rebuilt)))
    end)
  end)

  describe("landing", function()
    it("lands on the row for where you are when the sidebar is entered", function()
      local p = position.new()
      p:track({ path = "mod.lua", lnum = 5 })

      assert.equal(4, p:entered(view(ROWS, { focused = true })))
    end)

    it("lands on the nearest row on screen when yours is folded away", function()
      local p = position.new()
      p:track({ path = "mod.lua", lnum = 5 })

      assert.equal(2, p:entered(view(ROWS, { visible = shown(ROWS, { [MOD] = true }), focused = true })))
    end)

    it("leaves the cursor where it is when you are outside the changeset", function()
      local p = position.new()
      p:track(nil)

      assert.is_nil(p:entered(view(ROWS, { cursor = 8, focused = true })))
    end)

    it("follows a landing into your row when a rebuild brings it", function()
      local p = position.new()
      p:track({ path = "mod.lua", lnum = 5 })
      assert.equal(2, p:entered(view(READING, { focused = true })))

      assert.equal(4, p:rebuilt(view(ROWS, { cursor = 2, focused = true }), MOD, decided))
    end)

    it("follows a landing made before the tree had rows", function()
      local p = position.new()
      p:track({ path = "mod.lua", lnum = 5 })
      assert.is_nil(p:entered(view({}, { focused = true })))

      assert.equal(4, p:rebuilt(view(ROWS, { focused = true }), nil, decided))
    end)

    it("stops following a landing once you move the cursor", function()
      local p = position.new()
      p:track({ path = "mod.lua", lnum = 5 })
      p:entered(view(READING, { focused = true }))

      assert.is_nil(p:rebuilt(view(ROWS, { cursor = 8, focused = true }), OTHER, decided))
      assert.is_nil(p:rebuilt(view(ROWS, { cursor = 2, focused = true }), MOD, decided))
    end)

    it("stops following a landing once focus leaves the sidebar", function()
      local p = position.new()
      p:track({ path = "mod.lua", lnum = 5 })
      p:entered(view(READING, { focused = true }))

      assert.is_nil(p:rebuilt(view(ROWS, { cursor = 2 }), MOD, decided))
    end)
  end)

  describe("restored position", function()
    it("restores where you were once the tree has decided its file", function()
      local p = position.new()

      p:restore({ here = { path = "mod.lua", lnum = 5 } }, view(READING), reading)
      assert.same({}, p:marks(view(READING)))
      p:rebuilt(view(ROWS), MOD, decided)

      assert.same({ { kind = "here", lnum = 4 } }, p:marks(view(ROWS)))
    end)

    it("puts the cursor on the restored row once the tree has decided its file", function()
      local p = position.new()

      assert.is_nil(p:restore({ row = { id = LOAD, path = "mod.lua" } }, view(READING), reading))

      assert.equal(4, p:rebuilt(view(ROWS), MOD, decided))
    end)

    it("puts a restored row on the copy it recorded of a file shown in two sections", function()
      local p = position.new()

      assert.equal(5, p:restore({ row = { id = "#tests\0" .. RS, path = RS } }, view(SPLIT), decided))
    end)

    it("lets a restored row override the landing", function()
      local p = position.new()
      p:track({ path = "mod.lua", lnum = 5 })
      p:entered(view(READING, { focused = true }))
      p:restore({ row = { id = STOREFRONT, path = "mod.lua" } }, view(READING, { cursor = 2, focused = true }), reading)

      assert.equal(5, p:rebuilt(view(ROWS, { cursor = 2, focused = true }), MOD, decided))
    end)

    it("keeps a restored row waiting through a rebuild the landing follows", function()
      local p = position.new()
      p:track({ path = "mod.lua", lnum = 5 })
      p:entered(view(READING, { focused = true }))
      p:restore(
        { row = { id = OTHER_ORPHANS, path = "other.lua" } },
        view(READING, { cursor = 2, focused = true }),
        reading
      )
      local mod_decided = function(path)
        return path == "mod.lua"
      end
      assert.equal(4, p:rebuilt(view(ROWS, { cursor = 2, focused = true }), MOD, mod_decided))

      assert.equal(9, p:rebuilt(view(ROWS, { cursor = 4, focused = true }), LOAD, decided))
    end)

    it("does not pull the cursor off a restored row to follow an earlier landing", function()
      local p = position.new()
      p:track({ path = "mod.lua", lnum = 30 })
      local folded = shown(ROWS, { [MOD] = true })
      assert.equal(2, p:entered(view(ROWS, { visible = folded, focused = true })))
      assert.equal(
        2,
        p:restore({ row = { id = LOAD, path = "mod.lua" } }, view(ROWS, { visible = folded, cursor = 2 }), decided)
      )

      assert.is_nil(p:rebuilt(view(ROWS, { cursor = 2, focused = true }), MOD, decided))
    end)

    it("lets go of a restored row once you move the sidebar's cursor", function()
      local p = position.new()
      p:restore({ row = { id = LOAD, path = "mod.lua" } }, view(READING, { cursor = 3, focused = true }), reading)

      assert.is_nil(p:rebuilt(view(ROWS, { cursor = 9, focused = true }), OTHER_ORPHANS, decided))
    end)

    it("lets go of a restored row when the sidebar is entered", function()
      local p = position.new()
      p:track({ path = "mod.lua", lnum = 30 })
      p:restore({ row = { id = LOAD, path = "mod.lua" } }, view(READING, { cursor = 2 }), reading)
      p:entered(view(READING, { cursor = 2, focused = true }))

      assert.equal(6, p:rebuilt(view(ROWS, { cursor = 2, focused = true }), MOD, decided))
    end)

    it("lets go of a restored you are here once you move into a file", function()
      local p = position.new()
      p:restore({ here = { path = "mod.lua", lnum = 5 } }, view(READING), reading)

      p:track({ path = "other.lua", lnum = 3 })
      p:rebuilt(view(ROWS), MOD, decided)

      assert.same({ { kind = "here", lnum = 9 } }, p:marks(view(ROWS)))
    end)

    it("leaves you and the cursor alone for a recorded file and row the tree no longer holds", function()
      local p = position.new()
      p:track({ path = "other.lua", lnum = 3 })

      local lnum = p:restore({
        here = { path = "gone.lua", lnum = 3 },
        row = { id = MOD .. "\0gone", path = "mod.lua" },
      }, view(ROWS), decided)

      assert.is_nil(lnum)
      assert.same({ { kind = "here", lnum = 9 } }, p:marks(view(ROWS)))
    end)

    for name, value in pairs({
      ["null"] = vim.NIL,
      ["a string"] = "here",
      ["wrong types"] = { here = { path = 1, lnum = "8" }, row = { id = 2, path = {} } },
    }) do
      it("restores nothing from a recorded value that is " .. name, function()
        local p = position.new()

        p:restore(value, view(ROWS), reading)

        assert.same({}, p:saved(nil))
      end)
    end
  end)

  describe("saved", function()
    it("records where you are and the row under the sidebar's cursor", function()
      local p = position.new()
      p:track({ path = "mod.lua", lnum = 5 })

      assert.same({ here = { path = "mod.lua", lnum = 5 }, row = { id = LOAD, path = "mod.lua" } }, p:saved(row(LOAD)))
    end)

    it("records nothing while a restored position waits", function()
      local p = position.new()

      p:restore({ here = { path = "mod.lua", lnum = 5 } }, view(READING), reading)

      assert.is_nil(p:saved(nil))
    end)

    it("records again once a restored position settles", function()
      local p = position.new()
      p:restore({ here = { path = "mod.lua", lnum = 5 } }, view(READING), reading)

      p:rebuilt(view(ROWS), MOD, decided)

      assert.same({ here = { path = "mod.lua", lnum = 5 } }, p:saved(nil))
    end)

    it("records again once the diff cannot be read", function()
      local p = position.new()
      p:restore({ here = { path = "mod.lua", lnum = 5 } }, view(READING), reading)

      p:failed()

      assert.same({}, p:saved(nil))
    end)
  end)
end)
