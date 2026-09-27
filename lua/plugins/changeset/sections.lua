---Which part of a change a file belongs to, read off its path alone.

local M = {}

---@alias changeset.SectionKey "implementation"|"tests"|"docs"|"config"

---@class changeset.Section
---@field key changeset.SectionKey
---@field label string
---@field icon string Directory name `MiniIcons.get("directory", …)` draws the header's icon for.

---@type changeset.Section[] Display order.
M.ORDER = {
  { key = "implementation", label = "Implementation", icon = "src" },
  { key = "tests", label = "Tests", icon = "tests" },
  { key = "docs", label = "Docs", icon = "docs" },
  { key = "config", label = "Config", icon = ".config" },
}

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

---The section `path` belongs in. Rules run Tests → Docs → Config and the first match wins, so `tests/README.md` is a test; anything unmatched is Implementation.
---@param path string Repo-relative, `/`-separated.
---@return changeset.SectionKey
function M.classify(path)
  local dirs = vim.split(path, "/", { plain = true })
  local name = table.remove(dirs)
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

return M
