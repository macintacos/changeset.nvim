local sections = require("changeset.sections")

---@type table<changeset.SectionKey, string[]>
local cases = {
  generated = {
    "package-lock.json",
    "tests/fixtures/package-lock.json",
    "pnpm-lock.yaml",
    "Cargo.lock",
    "yarn.lock",
    "go.sum",
    "nvim-pack-lock.json",
    ".github/flake.lock",
  },
  tests = {
    "tests/fixtures/data.json",
    "tests/README.md",
    "lua/plugins/test/init.lua",
    "spec/models/user.rb",
    "src/__tests__/a.js",
    "pkg/testdata/in.txt",
    "auth_spec.lua",
    "auth_test.go",
    "auth.test.ts",
    "auth.spec.ts",
    "test_auth.py",
    "conftest.py",
    "run.bats",
  },
  docs = {
    "README.md",
    "README",
    "CHANGELOG",
    "guide.mdx",
    "index.rst",
    "nested/dir/notes.md",
    "docs/usage.txt",
    "doc/help.txt",
    ".github/CONTRIBUTING.md",
  },
  config = {
    "a.toml",
    "a.yaml",
    "a.yml",
    "hk.pkl",
    "a.json",
    "setup.cfg",
    "tox.ini",
    ".gitignore",
    ".editorconfig",
    ".github/workflows/ci.yml",
    ".github/CODEOWNERS",
    "Makefile",
    "Dockerfile",
    "go.mod",
    "package.json",
    "pyproject.toml",
    "Cargo.toml",
    "tsconfig.json",
    "lock.json",
  },
  implementation = {
    "plugin/lsp.lua",
    ".mise/tasks/test",
    "lua/plugins/changeset/init.lua",
    "notes.txt",
    ".github/scripts/a.sh",
    ".github/scripts/a.bash",
    ".github/scripts/a.py",
    ".github/scripts/a.js",
    ".github/scripts/a.ts",
    ".github/scripts/a.rs",
    ".github/scripts/a.go",
    ".github/scripts/a.lua",
    "a.json5",
    "notes.md.orig",
    "latest.ts",
    "contest.py",
    "testing/a.lua",
    "mydocs/a.txt",
  },
}

describe("sections", function()
  describe("classify", function()
    for key, paths in pairs(cases) do
      for _, path in ipairs(paths) do
        it(("puts %s under %s"):format(path, key), function()
          assert.equal(key, sections.classify(path))
        end)
      end
    end
  end)

  describe("test_rule", function()
    local ungated = {
      "src/main.go",
      "src/lib.lua",
      "scripts/run.sh",
      "config/app.yaml",
      "docs/guide.md",
      "tests/test_session.py",
      "src/session_test.rs",
      "src/session.test.ts",
      "src/app.js",
    }
    for _, path in ipairs(ungated) do
      it(("gives %s no rule"):format(path), function()
        assert.is_nil(sections.test_rule(path))
      end)
    end

    local modules_in = {
      { name = "tests", kind = "Module" },
      { name = "test", kind = "Module" },
      { name = "tests", kind = "Namespace" },
    }
    local modules_out = {
      { name = "tests", kind = "Function" },
      { name = "testing", kind = "Module" },
      { name = "session", kind = "Module" },
    }

    local function cb(name)
      return { name = name, kind = "Function" }
    end

    ---@type table<string, { accepts: { name: string, kind: string }[], rejects: { name: string, kind: string }[] }>
    local rules = {
      ["src/session.rs"] = {
        accepts = {},
        rejects = {
          { name = "test_refresh", kind = "Function" },
          { name = "TestSessionStore", kind = "Class" },
          cb("describe('x') callback"),
        },
      },
      ["pkg/session.py"] = {
        accepts = {
          { name = "test_refresh", kind = "Function" },
          { name = "TestSessionStore", kind = "Class" },
        },
        rejects = {
          { name = "refresh", kind = "Function" },
          { name = "testing", kind = "Function" },
          { name = "test_refresh", kind = "Variable" },
          { name = "Tester", kind = "Function" },
          cb("describe('x') callback"),
        },
      },
    }
    local ts = {
      accepts = {
        cb("describe('refresh') callback"),
        cb("it('refreshes') callback"),
        cb('test("reads the cache") callback'),
        cb("it.only('x') callback"),
      },
      rejects = {
        cb("setup('x') callback"),
        cb("items.forEach() callback"),
        cb("describe"),
        cb("itemize('x') callback"),
        cb("test_refresh"),
        { name = "TestSessionStore", kind = "Class" },
      },
    }
    for _, ext in ipairs({ "ts", "tsx", "mts", "cts" }) do
      rules["src/session." .. ext] = ts
    end

    for path, rule in pairs(rules) do
      describe(path, function()
        local accepts = vim.list_extend(vim.list_extend({}, modules_in), rule.accepts)
        local rejects = vim.list_extend(vim.list_extend({}, modules_out), rule.rejects)
        for _, sym in ipairs(accepts) do
          it(("accepts %s %s"):format(sym.kind, sym.name), function()
            assert.is_true(sections.test_rule(path)(sym))
          end)
        end
        for _, sym in ipairs(rejects) do
          it(("rejects %s %s"):format(sym.kind, sym.name), function()
            assert.is_false(sections.test_rule(path)(sym))
          end)
        end
      end)
    end

    describe("a symbol the syntax marked", function()
      for _, path in ipairs({
        "src/session.rs",
        "src/session.ts",
        "src/session.tsx",
        "src/session.mts",
        "src/session.cts",
      }) do
        describe(path, function()
          it("accepts it whatever its name", function()
            local rule = assert(sections.test_rule(path))
            assert.is_true(rule({ name = "refreshes_token", kind = "Function", test = true }))
            assert.is_true(rule({ name = "integration", kind = "Module", test = true }))
          end)

          it("rejects the same symbol unmarked", function()
            assert.is_false(sections.test_rule(path)({ name = "refreshes_token", kind = "Function" }))
          end)
        end)
      end
    end)
  end)

  it("puts a marked path under generated whatever else it is", function()
    assert.equal("generated", sections.classify("tests/a_spec.lua", true))
    assert.equal("generated", sections.classify("README.md", true))
    assert.equal("generated", sections.classify("api.go", true))
    assert.equal("implementation", sections.classify("api.go", false))
  end)

  it("orders implementation, tests, docs, config, generated", function()
    assert.same(
      { "implementation", "tests", "docs", "config", "generated" },
      vim.tbl_map(function(section)
        return section.key
      end, sections.ORDER)
    )
  end)
end)
