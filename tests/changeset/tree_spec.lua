local tree = require("plugins.changeset.tree")

local PATH = "src/session.ts"

---A flat `MiniPickers.Symbol` as `symbols.flatten` returns it, its body spanning `first..last`.
---@param name string
---@param kind string
---@param depth integer
---@param first integer
---@param last integer
---@return table
local function sym(name, kind, depth, first, last)
  return {
    name = name,
    text = name,
    kind = kind,
    path = PATH,
    lnum = first,
    col = 1,
    end_lnum = first,
    end_col = #name + 1,
    depth = depth,
    guides = "",
    crumb = "",
    range_lnum = first,
    range_end_lnum = last,
  }
end

---A `git diff --unified=0` hunk: `count` new lines replacing `removed` old ones.
---@param lnum integer
---@param count integer
---@param removed integer?
---@return changeset.Hunk
local function hunk(lnum, count, removed)
  return { lnum = lnum, count = count, added = count, removed = removed or 0 }
end

---@param path string
---@param hunks changeset.Hunk[]
---@param status string?
---@return changeset.File
local function file(path, hunks, status)
  local added, removed = 0, 0
  for _, h in ipairs(hunks) do
    added = added + h.added
    removed = removed + h.removed
  end
  return { path = path, status = status or "modified", added = added, removed = removed, hunks = hunks }
end

---@param rows changeset.Row[]
---@return string[]
local function names(rows)
  local out = {}
  for i, row in ipairs(rows) do
    out[i] = row.name
  end
  return out
end

---Every row id in `rows`, depth-first.
---@param rows changeset.Row[]
---@param out string[]?
---@return string[]
local function ids(rows, out)
  out = out or {}
  for _, row in ipairs(rows) do
    out[#out + 1] = row.id
    ids(row.children, out)
  end
  return out
end

describe("changeset.tree", function()
  describe("build", function()
    it("marks a file resolved once its symbols have arrived", function()
      local rows = tree.build({ file(PATH, { hunk(3, 1) }) }, { [PATH] = {} })

      assert.is_true(rows[1].resolved)
    end)

    it("leaves a file unresolved while its symbols are still outstanding", function()
      local rows = tree.build({ file(PATH, { hunk(3, 1) }) }, {})

      assert.is_false(rows[1].resolved)
    end)
  end)

  describe("build", function()
    describe("file rows", function()
      it("describes a file by its path, status and totals", function()
        local rows = tree.build({ file("src/new.ts", { hunk(1, 4) }, "added") }, {})

        local row = rows[1]
        assert.equal("src/new.ts", row.id)
        assert.equal("file", row.kind)
        assert.equal(0, row.depth)
        assert.equal("src/new.ts", row.name)
        assert.equal("src/new.ts", row.path)
        assert.equal("added", row.status)
        assert.equal(4, row.added)
        assert.equal(0, row.removed)
        assert.is_false(row.ancestor)
      end)

      it("gives a file whose symbols have not resolved no children, not even an orphan group", function()
        local rows = tree.build({ file(PATH, { hunk(5, 2) }) }, {})

        assert.equal(1, #rows)
        assert.same({}, rows[1].children)
      end)

      it("looks each file's symbols up by its own path", function()
        local rows = tree.build(
          { file("a.ts", { hunk(2, 1) }), file("b.ts", { hunk(2, 1) }) },
          { ["b.ts"] = { sym("f", "Function", 0, 1, 3) } }
        )

        assert.same({}, rows[1].children)
        assert.same({ "f" }, names(rows[2].children))
      end)

      it("jumps a file row to its first changed line", function()
        local rows = tree.build({ file(PATH, { hunk(12, 1), hunk(40, 3) }) }, {})

        assert.equal(12, rows[1].lnum)
      end)

      it("jumps a file with no hunks to the top", function()
        local rows = tree.build({ file("moved.ts", {}, "renamed") }, {})

        assert.equal(1, rows[1].lnum)
      end)

      it("jumps a file whose first change deletes the top of the file to line 1", function()
        local rows = tree.build({ file(PATH, { hunk(0, 0, 3) }) }, {})

        assert.equal(1, rows[1].lnum)
      end)

      it("makes a deleted file row non-navigable", function()
        local rows = tree.build({ file("gone.ts", { hunk(0, 0, 30) }, "deleted") }, {})

        assert.is_nil(rows[1].lnum)
      end)

      it("gives a deleted file row no stat", function()
        local rows = tree.build({ file("gone.ts", { hunk(0, 0, 30) }, "deleted") }, {})

        assert.is_nil(rows[1].added)
        assert.is_nil(rows[1].removed)
      end)
    end)

    describe("symbol rows", function()
      local STORE = {
        sym("SessionStore", "Class", 0, 3, 20),
        sym("refresh", "Method", 1, 5, 9),
        sym("expire", "Method", 1, 11, 15),
        sym("SESSION_TTL", "Constant", 0, 22, 22),
      }

      ---@param hunks changeset.Hunk[]
      ---@return changeset.Row[]
      local function build_store(hunks)
        return tree.build({ file(PATH, hunks) }, { [PATH] = STORE })[1].children
      end

      it("shows a class holding one changed method as a statless ancestor of it", function()
        local class = build_store({ hunk(7, 1) })[1]

        assert.equal("SessionStore", class.name)
        assert.is_true(class.ancestor)
        assert.is_nil(class.added)
        assert.is_nil(class.removed)
        assert.same({ "refresh" }, names(class.children))
      end)

      it("describes a changed symbol by its name line, kind and stat", function()
        local method = build_store({ hunk(7, 1, 2) })[1].children[1]

        assert.equal("symbol", method.kind)
        assert.equal(2, method.depth)
        assert.equal(PATH, method.path)
        assert.equal(5, method.lnum)
        assert.equal("Method", method.symbol_kind)
        assert.is_false(method.ancestor)
        assert.equal(1, method.added)
        assert.equal(2, method.removed)
        assert.same({}, method.children)
      end)

      it("keeps every changed method under a class that is only their ancestor", function()
        local class = build_store({ hunk(7, 1), hunk(12, 1) })[1]

        assert.is_true(class.ancestor)
        assert.same({ "refresh", "expire" }, names(class.children))
      end)

      it("nests by the depth sequence, so a top-level symbol after a class is its sibling", function()
        local rows = build_store({ hunk(7, 1), hunk(22, 1) })

        assert.same({ "SessionStore", "SESSION_TTL" }, names(rows))
        assert.equal(1, rows[2].depth)
      end)

      it("shows a class as changed when a hunk touches its own lines and no member", function()
        local rows = build_store({ hunk(4, 1) })

        assert.same({ "SessionStore" }, names(rows))
        assert.is_false(rows[1].ancestor)
        assert.equal(1, rows[1].added)
        assert.same({}, rows[1].children)
      end)

      it("shows no symbol when there is no hunk", function()
        assert.same({}, build_store({}))
      end)

      it("credits a deletion hunk to the symbol containing the line it follows", function()
        local method = build_store({ hunk(7, 0, 3) })[1].children[1]

        assert.equal("refresh", method.name)
        assert.is_false(method.ancestor)
        assert.equal(0, method.added)
        assert.equal(3, method.removed)
      end)

      it("credits a deletion on a method's first line to that method", function()
        local class = build_store({ hunk(11, 0, 1) })[1]

        assert.same({ "expire" }, names(class.children))
      end)

      -- expire spans 11..15
      for _, case in ipairs({
        { "starting on its first line", hunk(11, 1), true },
        { "ending on its last line", hunk(15, 1), true },
        { "running into it from above", hunk(9, 3), true },
        { "running out of it below", hunk(14, 4), true },
        { "sitting on the line before it", hunk(10, 1), false },
        { "sitting on the line after it", hunk(16, 1), false },
      }) do
        it("counts a hunk " .. case[1] .. (case[3] and " as touching" or " as missing") .. " a symbol", function()
          local class = build_store({ case[2] })[1]
          local touched = class ~= nil and vim.tbl_contains(names(class.children), "expire")

          assert.equal(case[3], touched)
        end)
      end
    end)

    describe("orphan hunks", function()
      local STORE = {
        sym("SessionStore", "Class", 0, 3, 20),
        sym("refresh", "Method", 1, 5, 9),
        sym("SESSION_TTL", "Constant", 0, 22, 22),
      }

      ---@param hunks changeset.Hunk[]
      ---@param line_text fun(path: string, lnum: integer): string?
      ---@return changeset.Row[]
      local function build_store(hunks, line_text)
        return tree.build({ file(PATH, hunks) }, { [PATH] = STORE }, line_text)[1].children
      end

      it("gathers hunks outside every symbol into one group after the symbol rows", function()
        local rows = build_store({ hunk(1, 2), hunk(7, 1), hunk(24, 1) })

        assert.same({ "SessionStore", "Other changes" }, names(rows))
        local group = rows[2]
        assert.equal("orphans", group.kind)
        assert.equal(1, group.depth)
        assert.equal(PATH, group.path)
        assert.is_false(group.ancestor)
        assert.same({ "L1–2", "L24" }, names(group.children))
        assert.equal("orphan", group.children[1].kind)
        assert.equal(2, group.children[1].depth)
        assert.same({}, group.children[1].children)
      end)

      it("leaves the symbol rows as they are without the orphan hunks", function()
        local with_orphan = build_store({ hunk(1, 2), hunk(7, 1) })
        local without = build_store({ hunk(7, 1) })

        assert.same(without[1], with_orphan[1])
      end)

      it("jumps an orphan hunk, and its group, to the hunk's first line", function()
        local group = build_store({ hunk(21, 1), hunk(24, 3) })[1]

        assert.equal(21, group.lnum)
        assert.equal(24, group.children[2].lnum)
      end)

      it("totals the group's stat from its hunks", function()
        local group = build_store({ hunk(1, 2, 1), hunk(24, 3, 4) })[1]

        assert.equal(5, group.added)
        assert.equal(5, group.removed)
        assert.equal(2, group.children[1].added)
        assert.equal(1, group.children[1].removed)
      end)

      it("names an orphan hunk by its lines and the trimmed text of its first one", function()
        local lines = { [1] = "  import a from 'a'  ", [24] = "\tmodule.exports = x" }
        local group = build_store({ hunk(1, 2), hunk(24, 1) }, function(path, lnum)
          return path == PATH and lines[lnum] or nil
        end)[1]

        assert.same({ "L1–2 import a from 'a'", "L24 module.exports = x" }, names(group.children))
      end)

      it("names a deletion orphan by its line alone, since the deleted text is not in the new file", function()
        local group = build_store({ hunk(21, 0, 2) }, function()
          return "the line before the deletion"
        end)[1]

        assert.same({ "L21" }, names(group.children))
      end)

      it("targets the first line for a deletion at the very top of a file", function()
        local group = build_store({ hunk(0, 0, 3) })[1]

        assert.same({ "L1" }, names(group.children))
        assert.equal(1, group.children[1].lnum)
      end)

      it("does not orphan a hunk that reaches into a symbol", function()
        assert.same({ "SessionStore" }, names(build_store({ hunk(1, 5) })))
      end)

      it("gives a file with resolved but no symbols only its orphan group", function()
        local rows = tree.build({ file("Makefile", { hunk(2, 2) }) }, { ["Makefile"] = {} })

        assert.same({ "Other changes" }, names(rows[1].children))
      end)

      it("gives a deleted file no children at all", function()
        local rows = tree.build({ file("gone.ts", { hunk(0, 0, 30) }, "deleted") }, { ["gone.ts"] = {} })

        assert.same({}, rows[1].children)
      end)
    end)

    describe("stats across symbols", function()
      -- one hunk running over 2..9 spans both functions
      local FUNCTIONS = { sym("first", "Function", 0, 1, 3), sym("second", "Function", 0, 5, 9) }

      ---@param hunks changeset.Hunk[]
      ---@return changeset.Row[]
      local function build_functions(hunks)
        return tree.build({ file(PATH, hunks) }, { [PATH] = FUNCTIONS })[1].children
      end

      it("counts a spanning hunk's added lines in each symbol only as far as they fall inside it", function()
        local rows = build_functions({ hunk(2, 8, 4) })

        assert.equal(2, rows[1].added)
        assert.equal(5, rows[2].added)
      end)

      it("credits a spanning hunk's removed lines to the first symbol it reaches", function()
        local rows = build_functions({ hunk(2, 8, 4) })

        assert.equal(4, rows[1].removed)
        assert.equal(0, rows[2].removed)
      end)

      it("sums the hunks that land in one symbol", function()
        local rows = build_functions({ hunk(5, 1, 2), hunk(8, 2, 1) })

        assert.equal(3, rows[1].added)
        assert.equal(3, rows[1].removed)
      end)
    end)

    describe("identity", function()
      it("identifies each row by its path and the full chain of names above it", function()
        local symbols = { sym("SessionStore", "Class", 0, 3, 20), sym("refresh", "Method", 1, 5, 9) }
        local file_row = tree.build({ file(PATH, { hunk(7, 1), hunk(24, 1) }) }, { [PATH] = symbols })[1]
        local class = file_row.children[1]
        local group = file_row.children[2]

        assert.equal("src/session.ts", file_row.id)
        assert.equal("src/session.ts\0SessionStore", class.id)
        assert.equal("src/session.ts\0SessionStore\0refresh", class.children[1].id)
        assert.equal("src/session.ts\0#orphans", group.id)
        assert.equal("src/session.ts\0#orphan:24", group.children[1].id)
      end)

      it("tells same-named symbols apart by where they nest", function()
        local symbols = {
          sym("A", "Class", 0, 1, 5),
          sym("run", "Method", 1, 2, 4),
          sym("B", "Class", 0, 7, 11),
          sym("run", "Method", 1, 8, 10),
        }
        local rows = tree.build({ file(PATH, { hunk(3, 1), hunk(9, 1) }) }, { [PATH] = symbols })[1].children

        assert.are_not.equal(rows[1].children[1].id, rows[2].children[1].id)
      end)
    end)
  end)

  describe("compress", function()
    -- Outer > Inner > two methods; Inner only ever has the one child until a second method changes.
    local NESTED = {
      sym("Outer", "Class", 0, 1, 30),
      sym("Inner", "Class", 1, 2, 29),
      sym("first", "Method", 2, 4, 8),
      sym("second", "Method", 2, 10, 14),
      sym("LIMIT", "Constant", 0, 32, 32),
    }

    local CHAIN = {
      sym("Outer", "Class", 0, 1, 30),
      sym("mid", "Method", 1, 3, 15),
      sym("leaf", "Function", 2, 5, 9),
    }

    ---@param hunks changeset.Hunk[]
    ---@param symbols table[]?
    ---@return changeset.Row[]
    local function build_nested(hunks, symbols)
      return tree.build({ file(PATH, hunks) }, { [PATH] = symbols or NESTED })
    end

    it("folds a chain of single-child symbols into one row aimed at the deepest", function()
      local rows = tree.compress(build_nested({ hunk(5, 2, 1), hunk(40, 1) }, CHAIN))

      local file_row = rows[1]
      assert.equal("file", file_row.kind)
      assert.equal(PATH, file_row.name)
      assert.same({ "Outer › mid › leaf", "Other changes" }, names(file_row.children))
      local chain = file_row.children[1]
      assert.equal("symbol", chain.kind)
      assert.equal(1, chain.depth)
      assert.equal(5, chain.lnum)
      assert.equal("Function", chain.symbol_kind)
      assert.is_false(chain.ancestor)
      assert.equal(2, chain.added)
      assert.equal(1, chain.removed)
      assert.same({}, chain.children)
    end)

    it("leaves a class with two changed methods alone, since it branches", function()
      local rows = build_nested({ hunk(5, 1), hunk(11, 1) }, {
        sym("SessionStore", "Class", 0, 3, 20),
        sym("refresh", "Method", 1, 5, 9),
        sym("expire", "Method", 1, 11, 15),
      })

      assert.same(rows, tree.compress(rows))
    end)

    it("ends a chain at a branch, keeping its children one level below the folded row", function()
      local file_row = tree.compress(build_nested({ hunk(5, 1), hunk(11, 1), hunk(32, 1) }))[1]

      assert.same({ "Outer › Inner", "LIMIT" }, names(file_row.children))
      local folded = file_row.children[1]
      assert.equal(1, folded.depth)
      assert.is_true(folded.ancestor)
      assert.is_nil(folded.added)
      assert.equal(2, folded.lnum)
      assert.same({ "first", "second" }, names(folded.children))
      assert.equal(2, folded.children[1].depth)
    end)

    it("never folds a file row into its only child, whether a symbol or an orphan group", function()
      local rows = tree.build({ file("Makefile", { hunk(2, 2) }), file("lib.lua", { hunk(2, 1) }) }, {
        ["Makefile"] = {},
        ["lib.lua"] = { sym("f", "Function", 0, 1, 3) },
      })

      assert.same(rows, tree.compress(rows))
    end)

    it("keeps the id of the chain's head, which the full tree also carries", function()
      local full = build_nested({ hunk(5, 1), hunk(11, 1), hunk(32, 1), hunk(40, 1) })
      local compressed = tree.compress(full)

      local full_ids = ids(full)
      for _, id in ipairs(ids(compressed)) do
        assert.is_true(vim.tbl_contains(full_ids, id), id)
      end
      assert.equal("src/session.ts\0Outer", compressed[1].children[1].id)
    end)

    it("marks a folded chain, keyed by its head and aimed at its deepest symbol", function()
      local file_row = tree.compress(build_nested({ hunk(5, 1) }, CHAIN))[1]
      local folded = file_row.children[1]

      assert.is_true(folded.chain)
      assert.equal("src/session.ts\0Outer", folded.id)
      assert.equal(5, folded.lnum)
      assert.is_nil(file_row.chain)
    end)

    it("does not mark a symbol that is not a chain", function()
      local file_row = tree.compress(build_nested({ hunk(5, 1), hunk(11, 1) }))[1]

      assert.is_nil(file_row.children[1].children[1].chain)
    end)

    describe("with is_open", function()
      local HEAD = "src/session.ts\0Outer"

      it("leaves a chain at full nesting when its head is open", function()
        local full = build_nested({ hunk(5, 1) }, CHAIN)

        assert.same(
          full,
          tree.compress(full, function(id)
            return id == HEAD
          end)
        )
      end)

      it("folds a chain when only a row below its head is open", function()
        local full = build_nested({ hunk(5, 1) }, CHAIN)
        local rows = tree.compress(full, function(id)
          return id == HEAD .. "\0mid"
        end)

        assert.same({ "Outer › mid › leaf" }, names(rows[1].children))
      end)

      it("still folds the chains below an open one", function()
        local full = build_nested({ hunk(5, 1), hunk(15, 1) }, {
          sym("Outer", "Class", 0, 1, 40),
          sym("Inner", "Class", 1, 2, 39),
          sym("A", "Method", 2, 3, 10),
          sym("a1", "Function", 3, 4, 8),
          sym("B", "Method", 2, 12, 20),
        })
        local rows = tree.compress(full, function(id)
          return id == HEAD
        end)

        local inner = rows[1].children[1].children[1]
        assert.equal("Inner", inner.name)
        assert.same({ "A › a1", "B" }, names(inner.children))
        assert.equal(3, inner.children[1].depth)
      end)
    end)

    it("leaves the full nesting intact so a folded chain can be expanded again", function()
      local full = build_nested({ hunk(5, 1) })
      local before = vim.deepcopy(full)

      tree.compress(full)

      assert.same(before, full)
    end)
  end)
end)
