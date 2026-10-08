---Reachable as `support.git` only because `tests/minimal_init.lua` puts `tests/`
---on `package.path`.
local M = {}

---Run git in `cwd`, asserting it succeeded.
---@param args string[]
---@param cwd string Repository to run in; relative paths in `args` resolve against it.
---@return string
function M.git(args, cwd)
  local out = vim.fn.system(vim.list_extend({ "git", "-C", cwd }, args))
  assert(vim.v.shell_error == 0, out)
  return vim.trim(out)
end

---Initialise a repo on `branch` with one empty commit, and return its SHA.
---@param branch string
---@param cwd string
---@return string
function M.init_repo(branch, cwd)
  M.git({ "init", "-q", "-b", branch }, cwd)
  -- A stray GIT_* var outranks `-C`, so without this the commits and config
  -- below would land in whatever repo it points at.
  local root = vim.fn.resolve(M.git({ "rev-parse", "--show-toplevel" }, cwd))
  assert(root == vim.fn.resolve(cwd), "fixture git repo escaped to " .. root)

  M.git({ "config", "user.email", "test@example.com" }, cwd)
  M.git({ "config", "user.name", "Test" }, cwd)
  M.git({ "config", "commit.gpgsign", "false" }, cwd)
  M.git({ "commit", "-q", "--allow-empty", "-m", "root" }, cwd)
  return M.git({ "rev-parse", "HEAD" }, cwd)
end

---Stage everything and commit it, returning the new HEAD.
---@param message string
---@param cwd string
---@return string
function M.commit(message, cwd)
  M.git({ "add", "-A" }, cwd)
  M.git({ "commit", "-q", "-m", message }, cwd)
  return M.git({ "rev-parse", "HEAD" }, cwd)
end

---Make a fresh temporary directory the process cwd, for code under test that resolves
---its repo from there.
---@return string dir
---@return string previous The cwd to return to.
function M.enter_tempdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local previous = vim.fn.chdir(dir)
  assert(previous ~= "", "could not enter the fixture directory")
  return dir, previous
end

---Write `files`, keyed by path relative to `cwd`.
---@param files table<string, string[]>
---@param cwd string
local function write_all(files, cwd)
  for path, lines in pairs(files) do
    vim.fn.writefile(lines, vim.fs.joinpath(cwd, path))
  end
end

---A repo on `trunk` with `base`, then a `feature` branch that writes `change` over it.
---@param base table<string, string[]>
---@param change table<string, string[]>
---@param cwd string
function M.feature(base, change, cwd)
  M.init_repo("trunk", cwd)
  write_all(base, cwd)
  M.commit("base", cwd)
  M.git({ "checkout", "-q", "-b", "feature" }, cwd)
  write_all(change, cwd)
  M.commit("change", cwd)
end

---@param count integer
---@param changed table<integer, true>? Lines to rewrite.
---@param word string? What each unchanged line says before its number; "line" by default.
---@return string[]
function M.numbered(count, changed, word)
  local lines = {}
  for i = 1, count do
    lines[i] = (changed or {})[i] and ("changed " .. i) or ((word or "line") .. " " .. i)
  end
  return lines
end

---A `feature` branch off `trunk` changing the one line of `mod.lua`.
---@param cwd string
function M.feature_one_file(cwd)
  M.feature({ ["mod.lua"] = { "return 1" } }, { ["mod.lua"] = { "return 2" } }, cwd)
end

---A `feature` branch off `trunk` changing `M.one` in `mod.lua` and the table in
---`other.lua`, beside a `plain.lua` it leaves alone.
---@param cwd string
function M.feature_two_files(cwd)
  M.feature({
    ["mod.lua"] = { "local M = {}", "", "function M.one()", "  return 1", "end", "", "return M" },
    ["other.lua"] = { "return { a = 1 }" },
    ["plain.lua"] = { "return 0" },
  }, {
    ["mod.lua"] = { "local M = {}", "", "function M.one()", "  return 2", "end", "", "return M" },
    ["other.lua"] = { "return { a = 1, b = 2 }" },
  }, cwd)
end

---A `feature` branch off `trunk` changing lines 2 and 8 of `mod.lua` and the last of
---`other.lua`, beside a `plain.lua` it leaves alone. Unless a spec stubs `resolve.start`,
---no server answers, so every hunk is an orphan: `mod.lua` → "Other changes" → L2, L8.
---@param cwd string
function M.feature_numbered(cwd)
  M.feature({
    ["mod.lua"] = M.numbered(10),
    ["other.lua"] = { "local a = 1", "", "return 1" },
    ["plain.lua"] = { "return 0" },
  }, {
    ["mod.lua"] = M.numbered(10, { [2] = true, [8] = true }),
    ["other.lua"] = { "local a = 1", "", "return 2" },
  }, cwd)
end

---A `feature` branch off `trunk` adding the 40 lines of `alpha.txt` and a line to `other.lua`.
---@param cwd string
function M.feature_alpha(cwd)
  M.feature({ ["other.lua"] = { "local M = {}", "return M" } }, {
    ["alpha.txt"] = M.numbered(40, nil, "alpha"),
    ["other.lua"] = { "local M = {}", "M.x = 1", "return M" },
  }, cwd)
end

return M
