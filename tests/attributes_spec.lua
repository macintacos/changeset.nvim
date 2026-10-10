local attributes = require("changeset.attributes")

---@param name string
---@param lnum integer
---@param kind string?
local function item(name, lnum, kind)
  return { name = name, kind = kind or "Function", lnum = lnum }
end

---@param path string
---@param lines string[]
---@param items { name: string, lnum: integer, test: true? }[]
---@return string[]
local function marked(path, lines, items)
  attributes.mark(items, path, table.concat(lines, "\n"))
  local names = {}
  for _, symbol in ipairs(items) do
    if symbol.test == true then
      names[#names + 1] = symbol.name
    end
  end
  table.sort(names)
  return names
end

local RUST_TEST = { "fn load() {}", "#[test]", "fn refreshes_token() {}", "fn save() {}" }
local VITEST = {
  "export function add(a: number, b: number) { return a + b }",
  "if (import.meta.vitest) {",
  "  const { it, expect } = import.meta.vitest",
  "  it('adds', () => {",
  "    expect(add(1, 2)).toBe(3)",
  "  })",
  "}",
}

describe("attributes", function()
  -- `mark` marks nothing without a parser, so every case below would fail as `{}` instead of naming the cause.
  for _, lang in ipairs(attributes.languages()) do
    assert.is_truthy(vim.treesitter.language.add(lang), lang .. " parser missing: run `mise run parsers` once")
  end

  describe("rust", function()
    it("marks a #[test] fn", function()
      local items = { item("load", 1), item("refreshes_token", 3), item("save", 4) }
      assert.same({ "refreshes_token" }, marked("src/session.rs", RUST_TEST, items))
    end)

    it("marks fns under a path ending in test, with or without arguments", function()
      local lines = {
        "#[tokio::test]",
        "async fn refreshes() {}",
        '#[tokio::test(flavor = "multi_thread")]',
        "async fn reloads() {}",
      }
      assert.same({ "refreshes", "reloads" }, marked("src/a.rs", lines, { item("refreshes", 2), item("reloads", 4) }))
    end)

    it("marks a #[cfg(test)] module and its contents past other attributes and doc comments", function()
      local lines = {
        "#[cfg(test)]",
        "#[allow(dead_code)]",
        "/// Helpers.",
        "mod integration {",
        "    fn helper() {}",
        "}",
        "fn after() {}",
      }
      local items = { item("integration", 4, "Module"), item("helper", 5), item("after", 7) }
      assert.same({ "helper", "integration" }, marked("src/a.rs", lines, items))
    end)

    it("marks a fn whose #[test] follows another attribute", function()
      local lines = { "#[should_panic]", "#[test]", "fn panics() {}" }
      assert.same({ "panics" }, marked("src/a.rs", lines, { item("panics", 3) }))
    end)

    it("marks a fn on its attribute's line", function()
      assert.same({ "inline" }, marked("src/a.rs", { "#[test] fn inline() {}" }, { item("inline", 1) }))
    end)

    for _, attr in ipairs({ "#[cfg(not(test))]", "#[cfg(all(test, unix))]", "#[derive(Debug)]", "#[test_case(1)]" }) do
      it("leaves a fn under " .. attr, function()
        assert.same({}, marked("src/a.rs", { attr, "fn f() {}" }, { item("f", 2) }))
      end)
    end

    it("leaves a module under #[path]", function()
      assert.same({}, marked("src/a.rs", { '#[path = "test"] mod g;' }, { item("g", 1, "Module") }))
    end)

    it("marks every one of hundreds of sibling #[test] fns", function()
      local lines, items = {}, {}
      for i = 1, 300 do
        vim.list_extend(lines, { "#[test]", "fn t" .. i .. "() {}" })
        items[i] = item("t" .. i, 2 * i)
      end
      assert.equal(300, #marked("src/a.rs", lines, items))
    end)

    it("leaves an unattributed fn named like a test", function()
      assert.same({}, marked("src/a.rs", { "fn test_helper() {}" }, { item("test_helper", 1) }))
    end)
  end)

  describe("typescript", function()
    for _, path in ipairs({ "src/math.ts", "src/math.tsx", "src/math.mts", "src/math.cts" }) do
      it("marks everything in an import.meta.vitest block in " .. path, function()
        local items = { item("add", 1), item("it", 3), item("expect", 3), item("it('adds') callback", 4) }
        assert.same({ "expect", "it", "it('adds') callback" }, marked(path, VITEST, items))
      end)
    end

    it("leaves a block under another import.meta property", function()
      local lines = { "if (import.meta.env) {", "  function setup() {}", "}" }
      assert.same({}, marked("src/a.ts", lines, { item("setup", 2) }))
    end)
  end)

  it("marks nothing in a file with no grammar for its extension", function()
    local lines = { "#[test]", "fn f() {}", "if (import.meta.vitest) {", "  f()", "}" }
    for _, path in ipairs({ "pkg/session.py", "src/main.go" }) do
      assert.same({}, marked(path, lines, { item("f", 2), item("g", 4) }))
    end
  end)

  describe("with no parser", function()
    local parse = vim.treesitter.query.parse
    local lines = vim.list_extend(vim.deepcopy(RUST_TEST), { "mod tests {", "    fn works() {}", "}" })
    local items ---@type table[]

    before_each(function()
      vim.treesitter.query.parse = function()
        error('No parser for language "rust"')
      end
      items = { item("refreshes_token", 3), item("tests", 5, "Module"), item("works", 6) }
    end)

    after_each(function()
      vim.treesitter.query.parse = parse
    end)

    it("marks nothing without raising", function()
      assert.same({}, marked("src/session.rs", lines, items))
    end)
  end)
end)
