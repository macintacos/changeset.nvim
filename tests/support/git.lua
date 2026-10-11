---Reachable as `support.git` only because `tests/minimal_init.lua` puts `tests/`
---on `package.path`.
local M = {}

---Run git in `cwd`, asserting it succeeded.
---@param args string[]
---@param cwd string Repository to run in; relative paths in `args` resolve against it.
---@return string
function M.git(args, cwd)
  local out = vim.fn.system(vim.list_extend({ "git", "-C", cwd }, args))
  assert.equal(0, vim.v.shell_error, out)
  return vim.trim(out)
end

---@class support.git.Template
---@field dir string
---@field value any What building it returned.

---The repos this process built, by what built them.
---@type table<string, support.git.Template>
local templates = {}

---Copy everything under `from` into `to`.
---@param from string
---@param to string
local function copy_tree(from, to)
  vim.fn.mkdir(to, "p")
  for name, kind in vim.fs.dir(from) do
    local source, target = vim.fs.joinpath(from, name), vim.fs.joinpath(to, name)
    if kind == "directory" then
      copy_tree(source, target)
    else
      local copied, err = vim.uv.fs_copyfile(source, target)
      assert.is_true(copied, err)
    end
  end
end

---Fill `cwd` with what `build` makes in an empty directory, returning what it returned. Each `key` is built once
---and copied after: spawning git is most of the suite's time.
---@generic T
---@param key string
---@param cwd string
---@param build fun(dir: string): T
---@return T
local function from_template(key, cwd, build)
  local template = templates[key]
  if not template then
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    template = { dir = dir, value = build(dir) }
    templates[key] = template
  end
  copy_tree(template.dir, cwd)
  return template.value
end

---Initialise a repo on `branch` with one empty commit, and return its SHA.
---@param branch string
---@param cwd string
---@return string
function M.init_repo(branch, cwd)
  return from_template("init " .. branch, cwd, function(dir)
    M.git({ "init", "-q", "-b", branch }, dir)
    -- A stray GIT_* var outranks `-C`, so without this the commit below would
    -- land in whatever repo it points at.
    local root = vim.fn.resolve(M.git({ "rev-parse", "--show-toplevel" }, dir))
    assert.equal(vim.fn.resolve(dir), root, "fixture git repo escaped to " .. root)

    M.git({ "commit", "-q", "--allow-empty", "-m", "root" }, dir)
    return M.git({ "rev-parse", "HEAD" }, dir)
  end)
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
  assert.not_equal("", previous, "could not enter the fixture directory")
  return dir, previous
end

---Write `files`, keyed by path relative to `cwd`.
---@param files table<string, string[]>
---@param cwd string
local function write_all(files, cwd)
  for path, lines in pairs(files) do
    local target = vim.fs.joinpath(cwd, path)
    vim.fn.mkdir(vim.fs.dirname(target), "p")
    vim.fn.writefile(lines, target)
  end
end

---A repo on `trunk` with `base`, then a `feature` branch that writes `change` over it.
---@param base table<string, string[]>
---@param change table<string, string[]>
---@param cwd string
function M.feature(base, change, cwd)
  from_template("feature " .. vim.inspect({ base, change }), cwd, function(dir)
    M.init_repo("trunk", dir)
    write_all(base, dir)
    M.commit("base", dir)
    M.git({ "checkout", "-q", "-b", "feature" }, dir)
    write_all(change, dir)
    M.commit("change", dir)
  end)
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
