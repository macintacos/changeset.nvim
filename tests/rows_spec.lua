local Rows = require("changeset.rows")
local Symbols = require("changeset.symbols")

local PATH = "src/session.ts"

local sym = require("support.changes").sym
local present = require("support.present")

---A `DocumentSymbol` as a server answers it, its body spanning `first..last`.
---@param name string
---@param kind string
---@param first integer
---@param last integer
---@param children table[]?
---@return table
local function lsp_sym(name, kind, first, last, children)
  local range = { start = { line = first - 1, character = 0 }, ["end"] = { line = last - 1, character = 0 } }
  return {
    name = name,
    kind = vim.lsp.protocol.SymbolKind[kind],
    range = range,
    selectionRange = range,
    children = children,
  }
end

---A `git diff --unified=0` hunk: `count` new lines replacing `removed` old ones.
---@param lnum integer
---@param count integer
---@param removed integer?
---@return changeset.Hunk
local function hunk(lnum, count, removed)
  return { lnum = lnum, count = count, added = count, removed = removed or 0, old_lnum = lnum }
end

---@param path string
---@param hunks changeset.Hunk[]
---@param status "added"|"modified"|"deleted"|"renamed"|"untracked"?
---@return changeset.File
local function file(path, hunks, status)
  local added, removed = 0, 0
  for _, h in ipairs(hunks) do
    added = added + h.added
    removed = removed + h.removed
  end
  return {
    path = path,
    status = status or "modified",
    section = require("changeset.sections").classify(path),
    added = added,
    removed = removed,
    hunks = hunks,
  }
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

local FILE_ID = "#implementation\0" .. PATH

describe("changeset.rows", function()
  local real_build = Rows.build

  -- Every case builds twice, so each also checks that the rows reused across builds equal the first ones.
  before_each(function()
    Rows.build = function(...)
      local rows = real_build(...)
      assert.same(rows, real_build(...))
      return rows
    end
  end)

  after_each(function()
    Rows.build = real_build
  end)

  describe("build", function()
    it("marks a file done once its symbols have arrived", function()
      local rows = Rows.files(Rows.build({ file(PATH, { hunk(3, 1) }) }, { [PATH] = {} }))

      assert.equal("done", present(rows[1]).read)
    end)

    it("leaves a file reading while its symbols are still outstanding", function()
      local rows = Rows.files(Rows.build({ file(PATH, { hunk(3, 1) }) }, {}))

      assert.equal("reading", present(rows[1]).read)
    end)
  end)

  describe("build", function()
    describe("section rows", function()
      it("puts non-empty sections at the top in display order", function()
        local rows = Rows.build({
          file("mise.toml", { hunk(1, 1) }),
          file("README.md", { hunk(1, 1) }),
          file("tests/a_spec.lua", { hunk(1, 1) }),
        }, {})

        assert.same({ "Tests", "Docs", "Config" }, names(rows))
        assert.same(
          { "section", "section", "section" },
          { present(rows[1]).kind, present(rows[2]).kind, present(rows[3]).kind }
        )
      end)

      it("gives a lone section its own row", function()
        local rows = Rows.build({ file(PATH, { hunk(1, 1) }) }, {})

        assert.same({ "Implementation" }, names(rows))
        assert.same({ PATH }, names(present(rows[1]).children))
      end)

      it("keeps the collected order of files within a section", function()
        local rows = Rows.build({ file("b.lua", { hunk(1, 1) }), file("a.lua", { hunk(1, 1) }) }, {})

        assert.same({ "b.lua", "a.lua" }, names(present(rows[1]).children))
      end)

      it("renders Generated last", function()
        local rows = Rows.build({
          file("go.sum", { hunk(1, 1) }),
          file("lua/a.lua", { hunk(1, 1) }),
          file("mise.toml", { hunk(1, 1) }),
        }, {})

        assert.same({ "Implementation", "Config", "Generated" }, names(rows))
      end)

      it("files a file the diff edge marked generated under Generated", function()
        local rows = Rows.build({
          vim.tbl_extend("force", file("api.go", { hunk(1, 1) }), { section = "generated" }) --[[@as changeset.File]],
        }, {})

        assert.same({ "Generated" }, names(rows))
      end)

      it("skips a Generated file whose symbols are never filed, with no children", function()
        local go_sum = present(Rows.build({ file("go.sum", { hunk(1, 1) }) }, {})[1]).children[1]

        assert.equal("skipped", present(go_sum).read)
        assert.same({}, present(go_sum).children)
      end)

      it("gives a Generated file no children, where another file gets its orphans", function()
        local rows = Rows.build(
          { file("lua/a.lua", { hunk(1, 1) }), file("go.sum", { hunk(1, 1) }) },
          { ["lua/a.lua"] = {}, ["go.sum"] = {} }
        )
        local go_sum = present(rows[2]).children[1]

        assert.same({ "Other changes" }, names(present(present(rows[1]).children[1]).children))
        assert.equal("skipped", present(go_sum).read)
        assert.same({}, present(go_sum).children)
      end)

      it("totals the whole section, a deleted file's numbers included", function()
        local section = Rows.build({
          file("a.lua", { hunk(1, 3, 1) }),
          file("b.lua", { hunk(0, 0, 5) }, "deleted"),
        }, {})[1]

        assert.equal(2, present(section).files)
        assert.equal(3, present(section).added)
        assert.equal(6, present(section).removed)
      end)
    end)

    describe("file rows", function()
      it("describes a file by its path, status and totals", function()
        local rows = Rows.files(Rows.build({ file("src/new.ts", { hunk(1, 4) }, "added") }, {}))

        local row = present(rows[1])
        assert.equal("#implementation\0src/new.ts", row.id)
        assert.equal("file", row.kind)
        assert.equal(1, row.depth)
        assert.equal("src/new.ts", row.name)
        assert.equal("src/new.ts", row.path)
        assert.equal("added", row.status)
        assert.equal(4, row.added)
        assert.equal(0, row.removed)
        assert.is_false(row.ancestor)
      end)

      it("gives a file whose symbols are still reading no children, not even an orphan group", function()
        local rows = Rows.files(Rows.build({ file(PATH, { hunk(5, 2) }) }, {}))

        assert.equal(1, #rows)
        assert.same({}, present(rows[1]).children)
      end)

      it("looks each file's symbols up by its own path", function()
        local rows = Rows.files(
          Rows.build(
            { file("a.ts", { hunk(2, 1) }), file("b.ts", { hunk(2, 1) }) },
            { ["b.ts"] = { sym("f", "Function", 0, 1, 3) } }
          )
        )

        assert.same({}, present(rows[1]).children)
        assert.same({ "f" }, names(present(rows[2]).children))
      end)

      it("jumps a file row to its first changed line", function()
        local rows = Rows.files(Rows.build({ file(PATH, { hunk(12, 1), hunk(40, 3) }) }, {}))

        assert.equal(12, present(rows[1]).lnum)
      end)

      it("jumps a file with no hunks to the top", function()
        local rows = Rows.files(Rows.build({ file("moved.ts", {}, "renamed") }, {}))

        assert.equal(1, present(rows[1]).lnum)
      end)

      it("jumps a file whose first change deletes the top of the file to line 1", function()
        local rows = Rows.files(Rows.build({ file(PATH, { hunk(0, 0, 3) }) }, {}))

        assert.equal(1, present(rows[1]).lnum)
      end)

      it("makes a deleted file row non-navigable", function()
        local rows = Rows.files(Rows.build({ file("gone.ts", { hunk(0, 0, 30) }, "deleted") }, {}))

        assert.is_nil(present(rows[1]).lnum)
      end)

      it("gives a deleted file row no stat", function()
        local rows = Rows.files(Rows.build({ file("gone.ts", { hunk(0, 0, 30) }, "deleted") }, {}))

        assert.is_nil(present(rows[1]).added)
        assert.is_nil(present(rows[1]).removed)
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
        return present(Rows.files(Rows.build({ file(PATH, hunks) }, { [PATH] = STORE }))[1]).children
      end

      it("shows a class holding one changed method as a stateless ancestor of it", function()
        local class = present(build_store({ hunk(7, 1) })[1])

        assert.equal("SessionStore", class.name)
        assert.is_true(class.ancestor)
        assert.is_nil(class.added)
        assert.is_nil(class.removed)
        assert.same({ "refresh" }, names(class.children))
      end)

      it("shows a class from a flat SymbolInformation answer as an ancestor of its changed method", function()
        local function info(name, kind, first, last)
          local range = { start = { line = first - 1, character = 0 }, ["end"] = { line = last - 1, character = 0 } }
          return { name = name, kind = kind, location = { uri = "file:///session.ts", range = range } }
        end
        local KIND = vim.lsp.protocol.SymbolKind
        local items = Symbols.flatten({ info("SessionStore", KIND.Class, 3, 20), info("refresh", KIND.Method, 5, 9) })

        local class = present(Rows.files(Rows.build({ file(PATH, { hunk(7, 1) }) }, { [PATH] = items }))[1]).children[1]

        assert.is_true(present(class).ancestor)
        assert.same({ "refresh" }, names(present(class).children))
      end)

      it("describes a changed symbol by its name line, kind and stat", function()
        local method = present(build_store({ hunk(7, 1, 2) })[1]).children[1]

        assert.equal("symbol", present(method).kind)
        assert.equal(3, present(method).depth)
        assert.equal(PATH, present(method).path)
        assert.equal(5, present(method).lnum)
        assert.equal("Method", present(method).symbol_kind)
        assert.is_false(present(method).ancestor)
        assert.equal(1, present(method).added)
        assert.equal(2, present(method).removed)
        assert.same({}, present(method).children)
      end)

      it("keeps every changed method under a class that is only their ancestor", function()
        local class = present(build_store({ hunk(7, 1), hunk(12, 1) })[1])

        assert.is_true(class.ancestor)
        assert.same({ "refresh", "expire" }, names(class.children))
      end)

      it("nests by the depth sequence, so a top-level symbol after a class is its sibling", function()
        local rows = build_store({ hunk(7, 1), hunk(22, 1) })

        assert.same({ "SessionStore", "SESSION_TTL" }, names(rows))
        assert.equal(2, present(rows[2]).depth)
      end)

      it("shows a class as changed when a hunk touches its own lines and no member", function()
        local rows = build_store({ hunk(4, 1) })

        assert.same({ "SessionStore" }, names(rows))
        assert.is_false(present(rows[1]).ancestor)
        assert.equal(1, present(rows[1]).added)
        assert.same({}, present(rows[1]).children)
      end)

      it("shows no symbol when there is no hunk", function()
        assert.same({}, build_store({}))
      end)

      it("credits a deletion hunk to the symbol containing the line it follows", function()
        local method = present(build_store({ hunk(7, 0, 3) })[1]).children[1]

        assert.equal("refresh", present(method).name)
        assert.is_false(present(method).ancestor)
        assert.equal(0, present(method).added)
        assert.equal(3, present(method).removed)
      end)

      it("credits a deletion on a method's first line to that method", function()
        local class = present(build_store({ hunk(11, 0, 1) })[1])

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

      it("gives a method its whole body's stat when its server also lists the method's locals", function()
        local response = {
          lsp_sym("SessionStore", "Class", 3, 20, {
            lsp_sym("sweep", "Method", 5, 16, {
              lsp_sym("dropped", "Variable", 6, 6),
              lsp_sym("id", "Variable", 7, 7),
              lsp_sym("session", "Variable", 8, 8),
            }),
          }),
        }
        local flat =
          require("changeset.symbols").flatten(response, require("changeset.kinds").for_filetype("typescript"))

        local class = present(Rows.files(Rows.build({ file(PATH, { hunk(5, 12) }) }, { [PATH] = flat }))[1]).children[1]
        local sweep = present(present(class).children[1])

        assert.same({ "sweep" }, names(present(class).children))
        assert.equal(12, sweep.added)
        assert.same({}, sweep.children)
      end)
    end)

    describe("orphan hunks", function()
      local STORE = {
        sym("SessionStore", "Class", 0, 3, 20),
        sym("refresh", "Method", 1, 5, 9),
        sym("SESSION_TTL", "Constant", 0, 22, 22),
      }

      ---@param hunks changeset.Hunk[]
      ---@param line_text? fun(path: string, lnum: integer): string?
      ---@return changeset.Row[]
      local function build_store(hunks, line_text)
        return present(Rows.files(Rows.build({ file(PATH, hunks) }, { [PATH] = STORE }, { text = line_text }))[1]).children
      end

      it("gathers hunks outside every symbol into one group after the symbol rows", function()
        local rows = build_store({ hunk(1, 2), hunk(7, 1), hunk(24, 1) })

        assert.same({ "SessionStore", "Other changes" }, names(rows))
        local group = present(rows[2])
        assert.equal("orphans", group.kind)
        assert.equal(2, group.depth)
        assert.equal(PATH, group.path)
        assert.is_false(group.ancestor)
        assert.same({ "L1–2", "L24" }, names(group.children))
        assert.equal("orphan", present(group.children[1]).kind)
        assert.equal(3, present(group.children[1]).depth)
        assert.same({}, present(group.children[1]).children)
      end)

      it("leaves the symbol rows as they are without the orphan hunks", function()
        local with_orphan = build_store({ hunk(1, 2), hunk(7, 1) })
        local without = build_store({ hunk(7, 1) })

        assert.same(without[1], with_orphan[1])
      end)

      it("jumps an orphan hunk, and its group, to the hunk's first line", function()
        local group = present(build_store({ hunk(21, 1), hunk(24, 3) })[1])

        assert.equal(21, group.lnum)
        assert.equal(24, present(group.children[2]).lnum)
      end)

      it("totals the group's stat from its hunks", function()
        local group = present(build_store({ hunk(1, 2, 1), hunk(24, 3, 4) })[1])

        assert.equal(5, group.added)
        assert.equal(5, group.removed)
        assert.equal(2, present(group.children[1]).added)
        assert.equal(1, present(group.children[1]).removed)
      end)

      it("names an orphan hunk by its lines and the trimmed text of its first one", function()
        local lines = { [1] = "  import a from 'a'  ", [24] = "\tmodule.exports = x" }
        local group = present(build_store({ hunk(1, 2), hunk(24, 1) }, function(path, lnum)
          return path == PATH and lines[lnum] or nil
        end)[1])

        assert.same({ "L1–2 import a from 'a'", "L24 module.exports = x" }, names(group.children))
      end)

      it("names a deletion orphan by its line alone, since the deleted text is not in the new file", function()
        local group = build_store({ hunk(21, 0, 2) }, function()
          return "the line before the deletion"
        end)[1]

        assert.same({ "L21" }, names(present(group).children))
      end)

      it("targets the first line for a deletion at the very top of a file", function()
        local group = present(build_store({ hunk(0, 0, 3) })[1])

        assert.same({ "L1" }, names(group.children))
        assert.equal(1, present(group.children[1]).lnum)
      end)

      it("does not orphan a hunk that reaches into a symbol", function()
        assert.same({ "SessionStore" }, names(build_store({ hunk(1, 5) })))
      end)

      it("gives a file read as having no symbols only its orphan group", function()
        local rows = Rows.files(Rows.build({ file("Makefile", { hunk(2, 2) }) }, { ["Makefile"] = {} }))

        assert.same({ "Other changes" }, names(present(rows[1]).children))
      end)

      it("gives a deleted file no children at all", function()
        local rows = Rows.files(Rows.build({ file("gone.ts", { hunk(0, 0, 30) }, "deleted") }, { ["gone.ts"] = {} }))

        assert.same({}, present(rows[1]).children)
      end)
    end)

    describe("stats across symbols", function()
      -- one hunk running over 2..9 spans both functions
      local FUNCTIONS = { sym("first", "Function", 0, 1, 3), sym("second", "Function", 0, 5, 9) }

      ---@param hunks changeset.Hunk[]
      ---@return changeset.Row
      local function build_file(hunks)
        return present(Rows.files(Rows.build({ file(PATH, hunks) }, { [PATH] = FUNCTIONS }))[1])
      end

      ---@param hunks changeset.Hunk[]
      ---@return changeset.Row[]
      local function build_functions(hunks)
        return build_file(hunks).children
      end

      it("counts a spanning hunk's added lines in each symbol only as far as they fall inside it", function()
        local rows = build_functions({ hunk(2, 8, 4) })

        assert.equal(2, present(rows[1]).added)
        assert.equal(5, present(rows[2]).added)
      end)

      it("credits a spanning hunk's removed lines to the first symbol it reaches", function()
        local rows = build_functions({ hunk(2, 8, 4) })

        assert.equal(4, present(rows[1]).removed)
        assert.equal(0, present(rows[2]).removed)
      end)

      it("sums the hunks that land in one symbol", function()
        local rows = build_functions({ hunk(5, 1, 2), hunk(8, 2, 1) })

        assert.equal(3, present(rows[1]).added)
        assert.equal(3, present(rows[1]).removed)
      end)

      it("leaves a file's total above the sum of its symbols when a hunk spans the gap between them", function()
        local file_row = build_file({ hunk(2, 8, 4) })
        local symbols_added = present(present(file_row.children[1]).added)
          + present(present(file_row.children[2]).added)

        assert.equal(8, file_row.added)
        assert.is_true(file_row.added > symbols_added)
      end)
    end)

    describe("identity", function()
      it("identifies each row by its section, its path and the full chain of names above it", function()
        local symbols = { sym("SessionStore", "Class", 0, 3, 20), sym("refresh", "Method", 1, 5, 9) }
        local section = present(Rows.build({ file(PATH, { hunk(7, 1), hunk(24, 1) }) }, { [PATH] = symbols })[1])
        local file_row = present(section.children[1])
        local class = present(file_row.children[1])
        local group = present(file_row.children[2])

        assert.equal(FILE_ID, file_row.id)
        assert.equal(FILE_ID .. "\0SessionStore", class.id)
        assert.equal(FILE_ID .. "\0SessionStore\0refresh", present(class.children[1]).id)
        assert.equal(FILE_ID .. "\0#orphans", group.id)
        assert.equal(FILE_ID .. "\0#orphans\0#orphan:24", present(group.children[1]).id)
        assert.same({ 0, 1, 2, 3 }, { section.depth, file_row.depth, class.depth, present(class.children[1]).depth })
        assert.same({ 2, 3 }, { group.depth, present(group.children[1]).depth })
      end)

      it("tells same-named symbols apart by where they nest", function()
        local symbols = {
          sym("A", "Class", 0, 1, 5),
          sym("run", "Method", 1, 2, 4),
          sym("B", "Class", 0, 7, 11),
          sym("run", "Method", 1, 8, 10),
        }
        local rows =
          present(Rows.files(Rows.build({ file(PATH, { hunk(3, 1), hunk(9, 1) }) }, { [PATH] = symbols }))[1]).children

        assert.not_equal(present(present(rows[1]).children[1]).id, present(present(rows[2]).children[1]).id)
      end)

      it("tells same-named siblings apart, as the overloads of one function are", function()
        local symbols = { sym("get", "Function", 0, 1, 3), sym("get", "Function", 0, 5, 7) }
        local rows =
          present(Rows.files(Rows.build({ file(PATH, { hunk(2, 1), hunk(6, 1) }) }, { [PATH] = symbols }))[1]).children

        assert.not_equal(present(rows[1]).id, present(rows[2]).id)
      end)
    end)
    describe("across builds", function()
      local STORE = { sym("SessionStore", "Class", 0, 3, 20), sym("refresh", "Method", 1, 5, 9) }
      local OTHER = "src/other.ts"

      it("returns the same file rows when built again from the same inputs", function()
        local files, symbols = { file(PATH, { hunk(7, 1), hunk(24, 1) }) }, { [PATH] = STORE }

        local first = Rows.files(Rows.build(files, symbols))
        local second = Rows.files(Rows.build(files, symbols))

        assert.equal(first[1], second[1])
      end)

      it("rebuilds only the file whose symbols were replaced", function()
        local files = { file(PATH, { hunk(7, 1) }), file(OTHER, { hunk(7, 1) }) }
        ---@type table<string, changeset.Symbol[]>
        local symbols = { [PATH] = STORE, [OTHER] = STORE }
        local first = Rows.files(Rows.build(files, symbols))

        symbols[OTHER] = { sym("refresh", "Function", 0, 5, 9) }
        local second = Rows.files(Rows.build(files, symbols))

        assert.equal(first[1], second[1])
        assert.not_equal(first[2], second[2])
        assert.same({ "refresh" }, names(present(second[2]).children))
      end)

      it("captions orphan hunks again once the file's tick moves", function()
        local files, symbols = { file(PATH, { hunk(24, 1) }) }, { [PATH] = STORE }
        local text, tick = "old", 1
        local lines = {
          text = function()
            return text
          end,
          tick = function()
            return tick
          end,
        }
        Rows.build(files, symbols, lines)

        text, tick = "new", 2
        local group = present(Rows.files(Rows.build(files, symbols, lines))[1]).children[1]

        assert.same({ "L24 new" }, names(present(group).children))
      end)

      it("captions orphan hunks once a build reads their text, after one that didn't", function()
        local files, symbols = { file(PATH, { hunk(24, 1) }) }, { [PATH] = STORE }
        Rows.build(files, symbols)

        local lines = {
          text = function()
            return "read"
          end,
        }
        local group = present(Rows.files(Rows.build(files, symbols, lines))[1]).children[1]

        assert.same({ "L24 read" }, names(present(group).children))
      end)

      it("reads two builds from the same inputs as the same rows", function()
        local files, symbols = { file(PATH, { hunk(7, 1) }), file(OTHER, { hunk(7, 1) }) }, { [PATH] = STORE }

        assert.is_true(Rows.same(Rows.build(files, symbols), Rows.build(files, symbols)))
      end)

      it("reads a build where one file's symbols arrived as other rows", function()
        local files, symbols = { file(PATH, { hunk(7, 1) }), file(OTHER, { hunk(7, 1) }) }, { [PATH] = STORE }
        local first = Rows.build(files, symbols)

        symbols[OTHER] = STORE

        assert.is_false(Rows.same(first, Rows.build(files, symbols)))
      end)

      it("totals each section afresh from the rows it reuses", function()
        local files, symbols = { file(PATH, { hunk(7, 1), hunk(24, 2) }) }, { [PATH] = STORE }
        local fresh = Rows.build(files, symbols)

        assert.same(fresh, Rows.build(files, symbols))
      end)
    end)
  end)

  describe("comments", function()
    it("lists a range ahead of a line inside it", function()
      local section = present(Rows.comments({
        { path = "a.lua", line = 3, body = "line" },
        { path = "a.lua", line = 4, start_line = 2, body = "range" },
      }))

      assert.equal("range", present(present(section.children[1]).review_comment).body)
    end)
  end)

  describe("skips", function()
    it("skips a deleted file", function()
      assert.is_true(Rows.skips(file(PATH, { hunk(1, 0, 1) }, "deleted")))
    end)

    it("skips a Generated file", function()
      assert.is_true(
        Rows.skips(
          vim.tbl_extend("force", file(PATH, { hunk(1, 1) }), { section = "generated" }) --[[@as changeset.File]]
        )
      )
    end)

    it("reads any other file", function()
      assert.is_false(Rows.skips(file(PATH, { hunk(1, 1) })))
    end)
  end)

  describe("read_status", function()
    local generated_go_file = vim.tbl_extend("force", file("api.go", { hunk(1, 1) }), { section = "generated" }) --[[@as changeset.File]]

    it("skips a deleted file", function()
      assert.equal("skipped", Rows.read_status(file(PATH, { hunk(1, 0, 1) }, "deleted"), {}))
    end)

    it("skips a Generated file whether or not its symbols are filed", function()
      assert.equal("skipped", Rows.read_status(file("go.sum", { hunk(1, 1) }), {}))
      assert.equal("skipped", Rows.read_status(file("go.sum", { hunk(1, 1) }), { ["go.sum"] = {} }))
      assert.equal("skipped", Rows.read_status(generated_go_file, {}))
      assert.equal("skipped", Rows.read_status(generated_go_file, { ["api.go"] = {} }))
    end)

    it("is reading a readable file with no symbols filed", function()
      assert.equal("reading", Rows.read_status(file(PATH, { hunk(1, 1) }), {}))
    end)

    it("is done with a readable file filed as having no symbols", function()
      assert.equal("done", Rows.read_status(file(PATH, { hunk(1, 1) }), { [PATH] = {} }))
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
      return Rows.build({ file(PATH, hunks) }, { [PATH] = symbols or NESTED })
    end

    it("folds a chain of single-child symbols into one row aimed at the deepest", function()
      local rows = Rows.compress(build_nested({ hunk(5, 2, 1), hunk(40, 1) }, CHAIN))

      local file_row = present(rows[1]).children[1]
      assert.equal("file", present(file_row).kind)
      assert.equal(PATH, present(file_row).name)
      assert.same({ "Outer › mid › leaf", "Other changes" }, names(present(file_row).children))
      local chain = present(present(file_row).children[1])
      assert.equal("symbol", chain.kind)
      assert.equal(2, chain.depth)
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

      assert.same(rows, Rows.compress(rows))
    end)

    it("ends a chain at a branch, keeping its children one level below the folded row", function()
      local file_row = present(Rows.compress(build_nested({ hunk(5, 1), hunk(11, 1), hunk(32, 1) }))[1]).children[1]

      assert.same({ "Outer › Inner", "LIMIT" }, names(present(file_row).children))
      local folded = present(present(file_row).children[1])
      assert.equal(2, folded.depth)
      assert.is_true(folded.ancestor)
      assert.is_nil(folded.added)
      assert.equal(2, folded.lnum)
      assert.same({ "first", "second" }, names(folded.children))
      assert.equal(3, present(folded.children[1]).depth)
    end)

    it("never folds a file row into its only child, whether a symbol or an orphan group", function()
      local rows = Rows.build({ file("Makefile", { hunk(2, 2) }), file("lib.lua", { hunk(2, 1) }) }, {
        ["Makefile"] = {},
        ["lib.lua"] = { sym("f", "Function", 0, 1, 3) },
      })

      assert.same(rows, Rows.compress(rows))
    end)

    it("keeps the id of the chain's head, which the full tree also carries", function()
      local full = build_nested({ hunk(5, 1), hunk(11, 1), hunk(32, 1), hunk(40, 1) })
      local compressed = Rows.compress(full)

      local full_ids = ids(full)
      for _, id in ipairs(ids(compressed)) do
        assert.is_true(vim.tbl_contains(full_ids, id), id)
      end
      local file_row = present(present(compressed[1]).children[1])
      assert.equal(FILE_ID .. "\0Outer", present(file_row.children[1]).id)
    end)

    it("marks a folded chain", function()
      local file_row = present(Rows.compress(build_nested({ hunk(5, 1) }, CHAIN))[1]).children[1]
      local folded = present(present(file_row).children[1])

      assert.is_true(folded.chain)
      assert.is_nil(present(file_row).chain)
    end)

    it("points a folded chain at the id of the deepest symbol it stands for", function()
      local file_row = present(present(Rows.compress(build_nested({ hunk(5, 1) }, CHAIN))[1]).children[1])
      local folded = present(file_row.children[1])

      assert.equal(FILE_ID .. "\0Outer\0mid\0leaf", folded.tip)
    end)

    it("does not mark a symbol that is not a chain", function()
      local file_row = present(Rows.compress(build_nested({ hunk(5, 1), hunk(11, 1) }))[1]).children[1]

      local symbol = present(present(file_row).children[1])
      assert.is_nil(present(symbol.children[1]).chain)
    end)

    describe("with is_open", function()
      local HEAD = FILE_ID .. "\0Outer"

      it("leaves a chain at full nesting when its head is open", function()
        local full = build_nested({ hunk(5, 1) }, CHAIN)

        assert.same(
          full,
          Rows.compress(full, function(id)
            return id == HEAD
          end)
        )
      end)

      it("folds a chain when only a row below its head is open", function()
        local full = build_nested({ hunk(5, 1) }, CHAIN)
        local rows = Rows.compress(full, function(id)
          return id == HEAD .. "\0mid"
        end)

        assert.same({ "Outer › mid › leaf" }, names(present(present(rows[1]).children[1]).children))
      end)

      it("still folds the chains below an open one", function()
        local full = build_nested({ hunk(5, 1), hunk(15, 1) }, {
          sym("Outer", "Class", 0, 1, 40),
          sym("Inner", "Class", 1, 2, 39),
          sym("A", "Method", 2, 3, 10),
          sym("a1", "Function", 3, 4, 8),
          sym("B", "Method", 2, 12, 20),
        })
        local rows = Rows.compress(full, function(id)
          return id == HEAD
        end)

        local inner = present(present(present(rows[1]).children[1]).children[1]).children[1]
        assert.equal("Inner", present(inner).name)
        assert.same({ "A › a1", "B" }, names(present(inner).children))
        assert.equal(4, present(present(inner).children[1]).depth)
      end)
    end)

    it("leaves the full nesting intact so a folded chain can be expanded again", function()
      local full = build_nested({ hunk(5, 1) })
      local before = vim.deepcopy(full)

      Rows.compress(full)

      assert.same(before, full)
    end)
  end)
  describe("locate", function()
    -- Class holding two methods, one of them changed, then an unchanged gap and a changed line past every symbol.
    local SYMBOLS = {
      sym("Store", "Class", 0, 1, 20),
      sym("load", "Method", 1, 3, 8),
      sym("save", "Method", 1, 10, 15),
    }

    ---@return changeset.Row[]
    local function rows()
      return Rows.build({ file(PATH, { hunk(5, 1), hunk(18, 1), hunk(30, 2) }), file("other.ts", {}) }, {
        [PATH] = SYMBOLS,
        ["other.ts"] = {},
      })
    end

    it("finds the deepest symbol row enclosing the line", function()
      assert.equal(FILE_ID .. "\0Store\0load", present(Rows.locate(rows(), PATH, 7)).id)
    end)

    it("stops at an ancestor row when the line is in its body but outside its changed members", function()
      assert.equal(FILE_ID .. "\0Store", present(Rows.locate(rows(), PATH, 12)).id)
    end)

    it("lands on the file's orphan group when the line is in a hunk outside every symbol", function()
      assert.equal(FILE_ID .. "\0#orphans", present(Rows.locate(rows(), PATH, 31)).id)
    end)

    it("falls back to the file row for a line in neither", function()
      assert.equal(FILE_ID, present(Rows.locate(rows(), PATH, 25)).id)
    end)

    it("finds nothing for a file the changeset does not hold", function()
      assert.is_nil(Rows.locate(rows(), "elsewhere.ts", 1))
    end)
  end)

  describe("comments", function()
    ---@param path string
    ---@param line integer
    ---@param start_line integer?
    ---@return changeset.ReviewComment
    local function review_comment(path, line, start_line)
      return { path = path, line = line, start_line = start_line, body = path .. ":" .. line .. " body\nmore" }
    end

    ---@param section changeset.Row
    ---@return string[]
    local function listed(section)
      return vim.tbl_map(function(row)
        return present(row.review_comment).body:match("^%S+")
      end, section.children)
    end

    it("lists the review comments by path, then line", function()
      local section =
        present((Rows.comments({ review_comment("b.ts", 3), review_comment("a.ts", 9), review_comment("a.ts", 2) })))

      assert.same({ "a.ts:2", "a.ts:9", "b.ts:3" }, listed(section))
    end)

    it("is nothing when there is nothing to list", function()
      assert.is_nil(Rows.comments({}))
    end)

    it("counts what it lists on its header, which carries no stat", function()
      local section = present(Rows.comments({ review_comment("a.ts", 9), review_comment("a.ts", 2) }))

      assert.equal("section", section.kind)
      assert.equal(2, section.comments)
      assert.is_nil(section.added)
    end)

    it("counts the drafts among what it lists", function()
      local draft = review_comment("a.ts", 2)
      draft.draft = true

      assert.equal(1, present(Rows.comments({ review_comment("a.ts", 9), draft })).drafts)
    end)

    it("goes to each listed line", function()
      local section = present(Rows.comments({ review_comment("a.ts", 9), review_comment("a.ts", 2) }))

      assert.same({ 2, 9 }, {
        present(section.children[1]).lnum,
        present(section.children[2]).lnum,
      })
    end)

    it("gives every row its own id, apart from every file section's", function()
      local section = present(Rows.comments({ review_comment("a.ts", 2), review_comment("a.ts", 2, 1) }))
      local distinct = { [section.id] = true }
      for _, row in ipairs(section.children) do
        distinct[row.id] = true
      end

      assert.equal(3, vim.tbl_count(distinct))
      assert.is_false(vim.list_contains(Rows.section_ids(), present(section.children[1]).id))
      assert.is_true(vim.list_contains(Rows.section_ids(), section.id))
    end)

    it("is never where a line of its file is located", function()
      local rows = Rows.build({ file(PATH, { hunk(5, 1) }) }, { [PATH] = {} })
      table.insert(rows, 1, (present(Rows.comments({ review_comment(PATH, 5) }))))

      assert.equal(FILE_ID .. "\0#orphans", present(Rows.locate(rows, PATH, 5)).id)
      assert.same(
        { FILE_ID },
        vim.tbl_map(function(row)
          return row.id
        end, Rows.files(rows))
      )
    end)
  end)

  describe("lines", function()
    ---A row of `kind` with `fields`.
    ---@param kind string
    ---@param fields table
    ---@return changeset.Row
    local function row(kind, fields)
      return vim.tbl_extend(
        "force",
        { id = "", kind = kind, depth = 1, name = "", path = "a", ancestor = false, children = {} },
        fields
      ) --[[@as changeset.Row]]
    end

    it("answers the lines a row stands for", function()
      assert.same({ 7, 7 }, { Rows.lines(row("function", { lnum = 7 })) })
      assert.same({ 3, 9 }, { Rows.lines(row("orphan", { range = { 3, 9 } })) })
      assert.same(
        { 2, 5 },
        { Rows.lines(row("comment", { review_comment = { path = "a", line = 5, start_line = 2, body = "" } })) }
      )
      assert.same({ 5, 5 }, { Rows.lines(row("comment", { review_comment = { path = "a", line = 5, body = "" } })) })
    end)

    it("answers none for a row standing for the whole file", function()
      assert.same({}, { Rows.lines(row("comment", { review_comment = { path = "a", body = "" } })) })
      assert.same({}, { Rows.lines(row("file", { lnum = 1 })) })
    end)
  end)

  describe("under", function()
    it("holds a row whose id extends the ancestor's by a segment, at any depth", function()
      assert.is_true(Rows.under("a\0b", "a"))
      assert.is_true(Rows.under("a\0b\0c", "a"))
    end)

    it("refuses an id that only starts with the ancestor's", function()
      assert.is_false(Rows.under("ab", "a"))
      assert.is_false(Rows.under("a\1" .. "2", "a"))
    end)

    it("refuses the ancestor itself", function()
      assert.is_false(Rows.under("a", "a"))
    end)
  end)

  describe("find", function()
    it("finds a row by its id at any depth", function()
      local rows = Rows.build({ file(PATH, { hunk(5, 1) }) }, { [PATH] = { sym("load", "Method", 0, 3, 8) } })

      assert.equal("load", present(Rows.find(rows, FILE_ID .. "\0load")).name)
      assert.is_nil(Rows.find(rows, FILE_ID .. "\0save"))
    end)
  end)

  describe("relocate", function()
    local rows = Rows.build({ file(PATH, { hunk(5, 1) }) }, { [PATH] = { sym("load", "Method", 0, 3, 8) } })

    it("keeps the picked row while the tree still holds it", function()
      local picked = { id = FILE_ID .. "\0load", path = PATH, lnum = 30 }

      assert.equal(FILE_ID .. "\0load", present(Rows.relocate(rows, picked)).id)
    end)

    it("resolves a picked row the tree dropped from its file and line", function()
      local picked = { id = FILE_ID .. "\0save", path = PATH, lnum = 5 }

      assert.equal(FILE_ID .. "\0load", present(Rows.relocate(rows, picked)).id)
    end)
  end)

  describe("inline tests", function()
    local RS = "src/session.rs"
    local IMPL_ID, TESTS_ID = "#implementation\0" .. RS, "#tests\0" .. RS
    -- A struct holding one method, then a test module holding one test.
    local SYMBOLS = {
      sym("SessionStore", "Struct", 0, 1, 20),
      sym("refresh", "Method", 1, 5, 12),
      sym("tests", "Module", 0, 30, 60),
      sym("refreshes", "Function", 1, 32, 40),
    }
    -- `session` holding a changed function and a nested test module.
    local NESTED = {
      sym("session", "Module", 0, 1, 60),
      sym("open", "Function", 1, 5, 10),
      sym("tests", "Module", 1, 30, 50),
      sym("refreshes", "Function", 2, 32, 40),
    }

    ---@param hunks changeset.Hunk[]
    ---@param symbols table[]?
    ---@return changeset.Row[] sections
    local function build(hunks, symbols)
      return Rows.build({ file(RS, hunks) }, { [RS] = symbols or SYMBOLS })
    end

    it("lists a file's test symbols under Tests and the rest under its path's section", function()
      local rows = build({ hunk(6, 2, 1), hunk(33, 3, 2), hunk(70, 1) })

      assert.same({ "Implementation", "Tests" }, names(rows))
      assert.same(
        { IMPL_ID },
        vim.tbl_map(function(r)
          return r.id
        end, present(rows[1]).children)
      )
      assert.same({ "SessionStore", "Other changes" }, names(present(present(rows[1]).children[1]).children))
      assert.same({ "refresh" }, names(present(present(present(rows[1]).children[1]).children[1]).children))
      assert.same({ TESTS_ID, TESTS_ID .. "\0tests", TESTS_ID .. "\0tests\0refreshes" }, ids(present(rows[2]).children))
    end)

    it("splits the file's stat between its copies", function()
      local rows = build({ hunk(6, 2, 1), hunk(33, 3, 2), hunk(70, 1) })
      local impl, tests = present(rows[1]).children[1], present(rows[2]).children[1]

      assert.same({ 3, 1 }, { present(impl).added, present(impl).removed })
      assert.same({ 3, 2 }, { present(tests).added, present(tests).removed })
    end)

    it("counts a hunk's lines inside a test module but outside its test on the Tests side", function()
      local rows = build({ hunk(31, 3), hunk(6, 1) })
      local second, first = present(present(rows[2]).children[1]), present(present(rows[1]).children[1])

      assert.same({ 3, 1 }, { second.added, first.added })
    end)

    it("splits a hunk crossing into a test module between its copies", function()
      local rows = build({ hunk(10, 25, 3) })
      local first, second = present(present(rows[1]).children[1]), present(present(rows[2]).children[1])

      assert.same({ 20, 3 }, { first.added, first.removed })
      assert.same({ 5, 0 }, { second.added, second.removed })
    end)

    it("counts removed lines handed to a test on the Tests side", function()
      local rows = build({ hunk(34, 0, 4), hunk(6, 1, 1) })
      local second, first = present(present(rows[2]).children[1]), present(present(rows[1]).children[1])

      assert.same({ 0, 4 }, { second.added, second.removed })
      assert.same({ 1, 1 }, { first.added, first.removed })
    end)

    it("totals both copies into their sections", function()
      local rows = build({ hunk(6, 2, 1), hunk(33, 3, 2) })

      assert.same({ 1, 2, 1 }, { present(rows[1]).files, present(rows[1]).added, present(rows[1]).removed })
      assert.same({ 1, 3, 2 }, { present(rows[2]).files, present(rows[2]).added, present(rows[2]).removed })
    end)

    it("places a test nested under a non-test symbol beneath that symbol as an ancestor", function()
      local rows = build({ hunk(6, 1), hunk(33, 2, 1) }, NESTED)
      local impl, tests = present(rows[1]).children[1], present(rows[2]).children[1]

      assert.same({ IMPL_ID, IMPL_ID .. "\0session", IMPL_ID .. "\0session\0open" }, ids({ impl }))
      assert.same({
        TESTS_ID,
        TESTS_ID .. "\0session",
        TESTS_ID .. "\0session\0tests",
        TESTS_ID .. "\0session\0tests\0refreshes",
      }, ids({ tests }))
      local nested = present(present(tests).children[1])
      assert.is_true(nested.ancestor)
      assert.is_nil(nested.added)
      assert.same({ 2, 1 }, { present(tests).added, present(tests).removed })
      assert.same({ 1, 0 }, { present(impl).added, present(impl).removed })
    end)

    it("shows a file whose changes are all in tests under Tests alone", function()
      local rows = build({ hunk(33, 2, 1) })
      local tests = present(present(rows[1]).children[1])

      assert.same({ "Tests" }, names(rows))
      assert.same({ TESTS_ID }, { tests.id })
      assert.same({ 2, 1 }, { tests.added, tests.removed })
    end)

    it("keeps one copy of a file that cannot split", function()
      local module = { sym("tests", "Module", 0, 1, 20) }
      ---@type [changeset.File, changeset.Symbol[]?][]
      local cases = {
        { file(RS, { hunk(5, 1) }), nil },
        { file(RS, { hunk(0, 0, 5) }, "deleted"), module },
        { file(RS, {}), module },
        { file("src/lib.lua", { hunk(5, 1) }), module },
        { file("src/main.go", { hunk(5, 1) }), { sym("TestRefresh", "Function", 0, 1, 20) } },
        { file("config/app.yaml", { hunk(5, 1) }), module },
        { file("tests/session_test.py", { hunk(5, 1) }), { sym("test_refresh", "Function", 0, 1, 20) } },
      }
      for _, case in ipairs(cases) do
        local path, symbols = case[1].path, case[2]
        local rows = Rows.build({ case[1] }, symbols and { [path] = symbols } or {})

        assert.equal(1, #Rows.files(rows), case[1].path)
      end
    end)

    describe("locate", function()
      local rows = build({ hunk(6, 2, 1), hunk(33, 3, 2), hunk(70, 1) })

      it("finds a test symbol in the Tests copy", function()
        assert.equal(TESTS_ID .. "\0tests\0refreshes", present(Rows.locate(rows, RS, 35)).id)
      end)

      it("finds an implementation symbol in the path section's copy", function()
        assert.equal(IMPL_ID .. "\0SessionStore\0refresh", present(Rows.locate(rows, RS, 8)).id)
      end)

      it("finds an orphan hunk in the path section's copy", function()
        assert.equal(IMPL_ID .. "\0#orphans", present(Rows.locate(rows, RS, 70)).id)
      end)

      it("falls back to the path section's file row", function()
        assert.equal(IMPL_ID, present(Rows.locate(rows, RS, 25)).id)
      end)

      it("prefers the copy with the deeper match", function()
        local nested = build({ hunk(6, 1), hunk(33, 2) }, NESTED)

        assert.equal(TESTS_ID .. "\0session\0tests", present(Rows.locate(nested, RS, 45)).id)
      end)

      it("breaks an equal-depth tie toward the path section's copy", function()
        local nested = build({ hunk(6, 1), hunk(33, 2) }, NESTED)

        assert.equal(IMPL_ID .. "\0session", present(Rows.locate(nested, RS, 20)).id)
      end)

      it("falls back to the only copy's file row", function()
        assert.equal(TESTS_ID, present(Rows.locate(build({ hunk(33, 2) }), RS, 25)).id)
      end)

      it("relocates a dropped pick into the Tests copy", function()
        local picked = { id = IMPL_ID .. "\0tests\0refreshes", path = RS, lnum = 35 }

        assert.equal(TESTS_ID .. "\0tests\0refreshes", present(Rows.relocate(rows, picked)).id)
      end)
    end)
  end)
  describe("comment-only changes", function()
    local LUA = "src/session.lua"
    local IMPL_ID, DOCS_ID = "#implementation\0" .. LUA, "#docs\0" .. LUA

    ---A `git diff --unified=0` hunk whose removed lines start at `old_lnum`.
    ---@param lnum integer
    ---@param count integer
    ---@param removed integer?
    ---@param old_lnum integer?
    ---@return changeset.Hunk
    local function h(lnum, count, removed, old_lnum)
      return { lnum = lnum, count = count, added = count, removed = removed or 0, old_lnum = old_lnum or lnum }
    end

    ---@param runs { comment: table?, directive: table?, blank: table? }
    ---@return changeset.LineKinds
    local function kinds(runs)
      return { comment = runs.comment or {}, directive = runs.directive or {}, blank = runs.blank or {} }
    end

    ---@param new table
    ---@param old table?
    ---@return changeset.Comments
    local function comments(new, old)
      return { new = kinds(new), old = kinds(old or {}) }
    end

    ---@param files changeset.File[]
    ---@param symbols_by_path table<string, table[]>
    ---@param comments_by_path table<string, changeset.Comments>
    ---@return changeset.Row[]
    local function build(files, symbols_by_path, comments_by_path)
      return Rows.build(files, symbols_by_path, { comments = comments_by_path })
    end

    ---The one-file build of `LUA`.
    ---@param hunks changeset.Hunk[]
    ---@param symbols table[]
    ---@param data changeset.Comments?
    ---@return changeset.Row[]
    local function build_lua(hunks, symbols, data)
      return build({ file(LUA, hunks) }, { [LUA] = symbols }, data and { [LUA] = data } or {})
    end

    ---@param row changeset.Row
    ---@return integer[]
    local function stat(row)
      return { row.added, row.removed }
    end

    describe("two functions", function()
      -- `a` holds a docstring on lines 4–5.
      local TWO = { sym("a", "Function", 0, 3, 10), sym("b", "Function", 0, 12, 20) }
      local DATA = comments({ comment = { { 4, 5 } } }, { comment = { { 4, 5 } } })

      it("lists a comment-only symbol under Docs and a code change under its path's section", function()
        local rows = build_lua({ h(4, 1, 1), h(15, 1, 1) }, TWO, DATA)

        assert.same({ "Implementation", "Docs" }, names(rows))
        assert.same({ IMPL_ID, IMPL_ID .. "\0b" }, ids(present(rows[1]).children))
        assert.same({ DOCS_ID, DOCS_ID .. "\0a" }, ids(present(rows[2]).children))
        assert.same({ 1, 1 }, stat(present(present(rows[1]).children[1])))
        assert.same({ 1, 1 }, stat(present(present(rows[2]).children[1])))
      end)

      it("keeps a symbol whose comment and code both change whole under its path's section", function()
        local rows = build_lua({ h(4, 1), h(7, 1) }, TWO, DATA)

        assert.same({ "Implementation" }, names(rows))
        assert.same({ IMPL_ID, IMPL_ID .. "\0a" }, ids(present(rows[1]).children))
      end)
    end)

    it("places a comment-only method under Docs beneath its bare class", function()
      local class = { sym("C", "Class", 0, 1, 30), sym("a", "Method", 1, 3, 10), sym("b", "Method", 1, 12, 20) }
      local rows = build_lua({ h(4, 1), h(15, 1) }, class, comments({ comment = { { 4, 4 } } }))

      assert.same({ IMPL_ID, IMPL_ID .. "\0C", IMPL_ID .. "\0C\0b" }, ids(present(rows[1]).children))
      assert.same({ DOCS_ID, DOCS_ID .. "\0C", DOCS_ID .. "\0C\0a" }, ids(present(rows[2]).children))
      assert.is_true(present(present(present(rows[2]).children[1]).children[1]).ancestor)
    end)

    describe("inline tests", function()
      local RS = "src/session.rs"
      local SYMBOLS = {
        sym("SessionStore", "Struct", 0, 1, 20),
        sym("refresh", "Method", 1, 5, 12),
        sym("tests", "Module", 0, 30, 60),
        sym("refreshes", "Function", 1, 32, 40),
        sym("expires", "Function", 1, 42, 50),
      }

      it("lists a comment-only test under Docs rather than Tests", function()
        local rows = build(
          { file(RS, { h(33, 1) }) },
          { [RS] = SYMBOLS },
          { [RS] = comments({ comment = { { 33, 33 } } }) }
        )

        assert.same({ "Docs" }, names(rows))
        assert.same(
          { "#docs\0" .. RS, "#docs\0" .. RS .. "\0tests", "#docs\0" .. RS .. "\0tests\0refreshes" },
          ids(present(rows[1]).children)
        )
      end)

      it("splits a file's stat across three copies, each counted in its own section", function()
        local data = comments({ comment = { { 43, 43 } } }, { comment = { { 43, 43 } } })
        local rows = build({ file(RS, { h(6, 2, 1), h(35, 1), h(43, 1, 1) }) }, { [RS] = SYMBOLS }, { [RS] = data })

        assert.same({ "Implementation", "Tests", "Docs" }, names(rows))
        assert.same({ 2, 1 }, stat(present(present(rows[1]).children[1])))
        assert.same({ 1, 0 }, stat(present(present(rows[2]).children[1])))
        assert.same({ 1, 1 }, stat(present(present(rows[3]).children[1])))
        for _, section in ipairs(rows) do
          assert.same(stat(present(section.children[1])), stat(section))
        end
      end)
    end)

    it("gives a file in any other path section a Docs copy", function()
      local spec = "tests/session_spec.lua"
      local rows = build(
        { file(spec, { h(3, 1), h(15, 1) }), file("mise.toml", { h(1, 1), h(5, 1) }) },
        { [spec] = { sym("a", "Function", 0, 1, 10), sym("b", "Function", 0, 12, 20) }, ["mise.toml"] = {} },
        { [spec] = comments({ comment = { { 3, 3 } } }), ["mise.toml"] = comments({ comment = { { 1, 1 } } }) }
      )

      assert.same({ "Tests", "Docs", "Config" }, names(rows))
      assert.same({ spec, "mise.toml" }, names(present(rows[2]).children))
    end)

    describe("a doc comment above a symbol", function()
      -- `f`'s range starts on line 5, below its doc comment on lines 3–4.
      local F = { sym("f", "Function", 0, 5, 10) }
      local DATA = comments({ comment = { { 3, 4 } } })
      -- `m`'s range starts on line 4, below its doc comment on lines 2–3.
      local CLASS = { sym("C", "Class", 0, 1, 20), sym("m", "Method", 1, 4, 8) }
      local CLASS_DATA = comments({ comment = { { 2, 3 } } })

      for _, case in ipairs({
        { "whose body changes too", F, DATA, { h(3, 1), h(7, 1) } },
        { "changed in one hunk with its first code line", F, DATA, { h(4, 2) } },
        { "of a class's first method whose body changes too", CLASS, CLASS_DATA, { h(2, 1), h(6, 1) } },
        { "of a class's first method changed with its first code line", CLASS, CLASS_DATA, { h(3, 2) } },
        { "beside a code line added directly above it", F, DATA, { h(2, 2) } },
      }) do
        it("keeps the symbol under its path's section when a doc comment " .. case[1] .. " changes", function()
          local rows = build_lua(case[4], case[2], case[3])

          assert.same({ "Implementation" }, names(rows))
          assert.is_nil(Rows.find(rows, IMPL_ID .. "\0#orphans"))
        end)
      end

      it("lists the symbol under Docs when only its doc comment changes", function()
        local rows = build_lua({ h(3, 1) }, F, DATA)

        assert.same({ DOCS_ID, DOCS_ID .. "\0f" }, ids(present(rows[1]).children))
      end)

      it("keeps a doc comment above a directive with its symbol", function()
        local data = comments({ comment = { { 2, 2 } }, directive = { { 3, 3 } } })
        local rows = build_lua({ h(2, 1) }, { sym("f", "Function", 0, 4, 10) }, data)

        assert.same({ DOCS_ID, DOCS_ID .. "\0f" }, ids(present(rows[1]).children))
      end)

      it("gives a doc comment to a container, not the member starting on its line", function()
        local symbols = { sym("handlers", "Variable", 0, 2, 2), sym("onClick", "Method", 1, 2, 2) }
        local rows = build_lua({ h(1, 1) }, symbols, comments({ comment = { { 1, 1 } } }))

        assert.same({ DOCS_ID, DOCS_ID .. "\0handlers" }, ids(present(rows[1]).children))
      end)
    end)

    describe("orphan hunks", function()
      it("gives each copy its own Other changes group", function()
        local rows = build_lua(
          { h(2, 1), h(25, 1) },
          { sym("f", "Function", 0, 10, 20) },
          comments({ comment = { { 2, 2 } } })
        )

        assert.same({ "Other changes" }, names(present(present(rows[1]).children[1]).children))
        assert.same({ "L25" }, names(present(present(present(rows[1]).children[1]).children[1]).children))
        assert.same({ "L2" }, names(present(present(present(rows[2]).children[1]).children[1]).children))
      end)

      it("judges each hunk of a file without symbols on its own", function()
        local rows = build_lua({ h(2, 1), h(5, 1) }, {}, comments({ comment = { { 2, 2 } } }))

        assert.same({ "Implementation", "Docs" }, names(rows))
        assert.same({ "L5" }, names(present(present(present(rows[1]).children[1]).children[1]).children))
        assert.same({ "L2" }, names(present(present(present(rows[2]).children[1]).children[1]).children))
      end)
    end)

    it("shows a file whose every change is a comment under Docs alone, with its whole stat", function()
      local data = comments({ comment = { { 2, 4 } } }, { comment = { { 3, 3 } } })
      local rows = build_lua({ h(2, 1), h(3, 2, 1) }, {}, data)

      assert.same({ "Docs" }, names(rows))
      assert.same({ 3, 1 }, stat(present(present(rows[1]).children[1])))
    end)

    describe("removed lines", function()
      local F = { sym("f", "Function", 0, 5, 10) }

      it("lists a symbol that only loses comment lines under Docs", function()
        local rows = build_lua({ h(6, 0, 2) }, F, comments({}, { comment = { { 6, 7 } } }))

        assert.same({ "Docs" }, names(rows))
      end)

      for _, case in ipairs({
        { "deletes code and adds a comment", comments({ comment = { { 6, 6 } } }, { comment = { { 9, 9 } } }) },
        { "comments code out", comments({ comment = { { 6, 6 } } }) },
        { "has no base side", { new = kinds({ comment = { { 6, 6 } } }) } },
      }) do
        it("keeps a symbol under its path's section when its change " .. case[1], function()
          local rows = build_lua({ h(6, 1, 1) }, F, case[2])

          assert.same({ "Implementation" }, names(rows))
        end)
      end
    end)

    describe("blank lines", function()
      local F = { sym("f", "Function", 0, 5, 10) }
      local DATA = comments({ comment = { { 6, 6 } }, blank = { { 7, 7 } } })

      it("lists a comment changed beside a blank line under Docs", function()
        assert.same({ "Docs" }, names(build_lua({ h(6, 2) }, F, DATA)))
      end)

      it("keeps a symbol whose only change is a blank line under its path's section", function()
        assert.same({ "Implementation" }, names(build_lua({ h(7, 1) }, F, DATA)))
      end)
    end)

    it("orders Docs copies among the files in Docs by the order it is handed them", function()
      local rows = build(
        { file("README.md", { h(1, 1) }), file(LUA, { h(2, 1) }), file("docs/b.md", { h(1, 1) }) },
        { ["README.md"] = {}, [LUA] = {}, ["docs/b.md"] = {} },
        { [LUA] = comments({ comment = { { 2, 2 } } }) }
      )

      assert.same({ "README.md", LUA, "docs/b.md" }, names(present(rows[1]).children))
    end)

    describe("locate", function()
      local TWO = { sym("a", "Function", 0, 3, 10), sym("b", "Function", 0, 12, 20) }
      local DATA = comments({ comment = { { 4, 5 } } })

      it("finds a comment-only symbol in the Docs copy", function()
        assert.equal(DOCS_ID .. "\0a", present(Rows.locate(build_lua({ h(4, 1), h(15, 1) }, TWO, DATA), LUA, 7)).id)
      end)

      it("finds a code symbol in the path section's copy", function()
        assert.equal(IMPL_ID .. "\0b", present(Rows.locate(build_lua({ h(4, 1), h(15, 1) }, TWO, DATA), LUA, 15)).id)
      end)

      it("prefers a changed row to a bare ancestor at the same depth", function()
        -- `C`'s own doc comment on line 2 changes, and so does code in its method `m`.
        local class = { sym("C", "Class", 0, 1, 30), sym("m", "Method", 1, 10, 20) }
        local rows = build_lua({ h(2, 1), h(15, 1) }, class, comments({ comment = { { 2, 2 } } }))

        assert.equal(DOCS_ID .. "\0C", present(Rows.locate(rows, LUA, 25)).id)
      end)

      it("falls back to the path section's copy even when it lists after Docs", function()
        local rows = build({ file("mise.toml", { h(1, 1), h(5, 1) }) }, { ["mise.toml"] = {} }, {
          ["mise.toml"] = comments({ comment = { { 1, 1 } } }),
        })

        assert.equal("#config\0mise.toml", present(Rows.locate(rows, "mise.toml", 9)).id)
      end)
    end)

    describe("a file keeps its path's copy alone", function()
      local ALL = comments({ comment = { { 1, 9 } } })

      ---@type [string, string, changeset.Symbol[]?, changeset.Comments?, string][]
      local cases = {
        { "while it is still resolving", LUA, nil, ALL, "Implementation" },
        { "without comment data", LUA, {}, nil, "Implementation" },
        { "when it is Generated", "go.sum", {}, ALL, "Generated" },
        { "when its path puts it in Docs", "README.md", {}, ALL, "Docs" },
      }
      for _, case in ipairs(cases) do
        it(case[1], function()
          local path, symbols, comment_lines = case[2], case[3], case[4]
          local rows = build(
            { file(path, { h(2, 1) }) },
            symbols and { [path] = symbols } or {},
            comment_lines and { [path] = comment_lines } or {}
          )

          assert.same({ case[5] }, names(rows))
          assert.equal(1, #Rows.files(rows))
        end)
      end
    end)
  end)
end)
