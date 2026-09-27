local sections = require("plugins.changeset.sections")

---@type table<changeset.SectionKey, string[]>
local cases = {
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

  it("orders implementation, tests, docs, config", function()
    assert.same(
      { "implementation", "tests", "docs", "config" },
      vim.tbl_map(function(section)
        return section.key
      end, sections.ORDER)
    )
  end)
end)
