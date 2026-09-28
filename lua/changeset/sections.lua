---Which part of a change a file, or a symbol inside it, belongs to; a file by its path and whether its content or `.gitattributes` marks it generated.

local M = {}

---@alias changeset.SectionKey "implementation"|"tests"|"docs"|"config"|"generated"

---@class changeset.Section
---@field key changeset.SectionKey
---@field label string
---@field icon string Directory name `icons.get("directory", …)` draws the header's icon for.

---@type changeset.Section[] Display order.
M.ORDER = {
  { key = "implementation", label = "Implementation", icon = "src" },
  { key = "tests", label = "Tests", icon = "tests" },
  { key = "docs", label = "Docs", icon = "docs" },
  { key = "config", label = "Config", icon = ".config" },
  { key = "generated", label = "Generated", icon = "build" },
}

local GENERATED_FILES = vim.glob.to_lpeg("{*.lock,*-lock.json,*-lock.yaml,go.sum}")
local TEST_DIRS = { tests = true, test = true, spec = true, __tests__ = true, testdata = true }
local TEST_FILES = vim.glob.to_lpeg("{*_spec.*,*_test.*,*.test.*,*.spec.*,test_*.py,conftest.py,*.bats}")
local DOC_FILES = vim.glob.to_lpeg("{*.md,*.mdx,*.rst,README*,CHANGELOG*}")
local DOC_DIRS = { doc = true, docs = true }
local CONFIG_FILES = vim.glob.to_lpeg("{*.toml,*.yaml,*.yml,*.pkl,*.json,*.ini,*.cfg,.*,Makefile,Dockerfile,go.mod}")
local CONFIG_DIRS = { [".github"] = true }
local SCRIPT_FILES = vim.glob.to_lpeg("{*.sh,*.bash,*.py,*.js,*.ts,*.rs,*.go,*.lua}")

---@param dirs string[]
---@param names table<string, true>
---@return boolean
local function has_dir(dirs, names)
  return vim.iter(dirs):any(function(dir)
    return names[dir] ~= nil
  end)
end

---The section `path` belongs in. Generated beats every other rule; then Tests → Docs → Config, and the first match wins, so `tests/README.md` is a test; anything unmatched is Implementation.
---@param path string Repo-relative, `/`-separated.
---@param marked boolean? Whether its Go header or `.gitattributes` marks it generated.
---@return changeset.SectionKey
function M.classify(path, marked)
  local dirs = vim.split(path, "/", { plain = true })
  local name = table.remove(dirs)
  if marked or GENERATED_FILES:match(name) then
    return "generated"
  end
  if has_dir(dirs, TEST_DIRS) or TEST_FILES:match(name) then
    return "tests"
  end
  if DOC_FILES:match(name) or (vim.endswith(name, ".txt") and has_dir(dirs, DOC_DIRS)) then
    return "docs"
  end
  if CONFIG_FILES:match(name) or (has_dir(dirs, CONFIG_DIRS) and not SCRIPT_FILES:match(name)) then
    return "config"
  end
  return "implementation"
end

---Whether a symbol is an inline test; one that is takes everything beneath it to Tests.
---@alias changeset.SymbolRule fun(sym: { name: string, kind: string, test: true? }): boolean

local TEST_MODULES = { test = true, tests = true }
local TEST_CALLS = { describe = true, it = true, test = true }

---A module or namespace named `test` or `tests`, as Rust's `mod tests` is.
---@param sym { name: string, kind: string }
---@return boolean
local function test_module(sym)
  return (sym.kind == "Module" or sym.kind == "Namespace") and TEST_MODULES[sym.name] ~= nil
end

---@type changeset.SymbolRule
local function ts_test(sym)
  -- tsserver names a callback after the call it is passed to: `describe('refresh') callback`; a call counts by
  -- its head, so `it.only(…)` and `describe.skip(…)` are the blocks they wrap.
  local callee = sym.name:match("^([%w_$.]+)%(.*%) callback$")
  return test_module(sym) or (callee ~= nil and TEST_CALLS[callee:match("^[^.]+")] ~= nil)
end

---@type table<string, changeset.SymbolRule> By file extension.
local TEST_SYMBOLS = {
  rs = test_module,
  py = function(sym)
    return test_module(sym)
      or (sym.kind == "Function" and vim.startswith(sym.name, "test_"))
      or (sym.kind == "Class" and vim.startswith(sym.name, "Test"))
  end,
  ts = ts_test,
  tsx = ts_test,
  mts = ts_test,
  cts = ts_test,
}

---The rule marking `path`'s inline test symbols: one it accepts goes to Tests with everything beneath it. A symbol
---flagged `test` (`changeset.attributes`) counts whatever its name. Only Rust, Python and TypeScript files
---the path rules put in Implementation get one.
---@param path string Repo-relative, `/`-separated.
---@return changeset.SymbolRule?
function M.test_rule(path)
  if M.classify(path) ~= "implementation" then
    return nil
  end
  local by_name = TEST_SYMBOLS[path:match("%.(%w+)$")]
  return by_name and function(sym)
    return sym.test == true or by_name(sym)
  end
end

return M
