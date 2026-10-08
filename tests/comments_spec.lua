local comments = require("changeset.comments")

---Each line's kind, in order.
---@param path string
---@param lines string[]
---@return string[]
local function kinds(path, lines)
  local read
  comments.read(table.concat(lines, "\n"), path, function(found)
    read = found
  end)
  assert(read, "no kinds read before read returned")
  return vim.tbl_map(function(lnum)
    return comments.kind(read, lnum)
  end, vim.fn.range(1, #lines))
end

describe("comments", function()
  -- `read` answers nil without a parser, so every case below would fail on `assert` instead of naming the cause.
  for _, lang in ipairs({ "lua", "python", "rust", "toml", "typescript" }) do
    assert(vim.treesitter.language.add(lang), lang .. " parser missing: run `mise run parsers` once")
  end

  it("reads Lua line, doc and block comments", function()
    local lines = { "-- a", "--- b", "---@param x integer", "--[[ c", "d ]]", "local x = 1" }
    assert.same({ "comment", "comment", "comment", "comment", "comment", "code" }, kinds("lua/a.lua", lines))
  end)

  describe("python", function()
    it("reads # comments", function()
      assert.same({ "comment", "code" }, kinds("a.py", { "# note", "x = 1" }))
    end)

    it("reads module, class and function docstrings", function()
      local lines = {
        '"""Module."""',
        "class A:",
        '    """Class',
        '    more."""',
        "    def f(self):",
        '        """Function."""',
        "        return 1",
      }
      assert.same({ "comment", "code", "comment", "comment", "code", "comment", "code" }, kinds("a.py", lines))
    end)

    it("reads a module docstring after a shebang", function()
      assert.same(
        { "directive", "comment", "code" },
        kinds("a.py", {
          "#!/usr/bin/env python",
          '"""Doc."""',
          "x = 1",
        })
      )
    end)

    it("reads a module docstring after a comment", function()
      assert.same({ "comment", "comment", "code" }, kinds("a.py", { "# c", '"""Doc."""', "x = 1" }))
    end)

    it("reads a string that is not a first statement as code", function()
      assert.same({ "code", "code" }, kinds("a.py", { "x = 1", '"""Not a docstring."""' }))
    end)
  end)

  it("reads Rust line, doc and block comments", function()
    assert.same(
      { "comment", "comment", "comment", "comment", "code" },
      kinds("src/a.rs", { "// a", "/// b", "/* c", "d */", "fn f() {}" })
    )
  end)

  it("reads a Rust doc comment directly above an item", function()
    assert.same({ "comment", "code" }, kinds("src/a.rs", { "/// b", "fn f() {}" }))
  end)

  it("picks the language of an extensionless script from its shebang", function()
    assert.same(
      { "directive", "comment", "code" },
      kinds("bin/deploy", { "#!/usr/bin/env python3", "# note", "x = 1" })
    )
  end)

  it("reads TypeScript line and doc comments", function()
    assert.same(
      { "comment", "comment", "comment", "comment", "code" },
      kinds("src/a.ts", { "// a", "/**", " * b", " */", "const x = 1" })
    )
  end)

  it("reads TOML comments", function()
    assert.same({ "comment", "code" }, kinds("a.toml", { "# note", "x = 1" }))
  end)

  it("reads a line with code before its comment as code", function()
    assert.same({ "code" }, kinds("a.py", { "x = 1  # note" }))
  end)

  it("reads a whitespace-only line as blank", function()
    assert.same({ "code", "blank", "code" }, kinds("a.py", { "x = 1", "   ", "y = 2" }))
  end)

  describe("directives", function()
    it("reads build, embed, ts and eslint comments as directives", function()
      local lines = {
        "//go:build linux",
        "//go:embed a.txt",
        "// @ts-expect-error",
        "// eslint-disable-next-line",
        "const x = 1",
      }
      assert.same({ "directive", "directive", "directive", "directive", "code" }, kinds("src/a.ts", lines))
    end)

    it("reads ---@diagnostic as a directive", function()
      assert.same({ "directive", "code" }, kinds("a.lua", { "---@diagnostic disable", "local x = 1" }))
    end)

    it("reads a shebang as a directive", function()
      assert.same({ "directive", "code" }, kinds("a.py", { "#!/usr/bin/env python", "x = 1" }))
    end)
  end)

  it("reads nothing for a language with no installed parser", function()
    local called, found = false, "unset"
    comments.read("x", "a.unknownext", function(kinds_read)
      called, found = true, kinds_read
    end)
    assert.is_true(called)
    assert.is_nil(found)
  end)

  describe("a source too large to parse in one slice", function()
    local lines = {}
    for i = 1, 20000, 2 do
      lines[i], lines[i + 1] = "-- note " .. i, "local x" .. i .. " = { " .. i .. ", 'text' }"
    end
    local source = table.concat(lines, "\n")

    ---@param found changeset.LineKinds
    local function assert_alternating(found)
      for _, lnum in ipairs({ 1, 2, 9999, 10000, 19999, 20000 }) do
        assert.equal(lnum % 2 == 1 and "comment" or "code", comments.kind(found, lnum))
      end
    end

    local redrawtime
    before_each(function()
      redrawtime = vim.o.redrawtime
    end)
    after_each(function()
      vim.o.redrawtime = redrawtime
    end)

    it("calls back after read returns, with every line's kind", function()
      local found
      comments.read(source, "big.lua", function(kinds_read)
        found = kinds_read
      end)
      assert.is_nil(found)
      assert.is_true(vim.wait(10000, function()
        return found ~= nil
      end, 1))
      assert_alternating(found)
    end)

    it("still reads every line's kind once its parse outlasts 'redrawtime'", function()
      vim.o.redrawtime = 1
      local found
      comments.read(source, "big.lua", function(kinds_read)
        found = kinds_read
      end)
      assert.is_true(vim.wait(10000, function()
        return found ~= nil
      end, 1))
      assert_alternating(found)
    end)
  end)
end)
