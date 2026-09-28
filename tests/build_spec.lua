local changeset = require("changeset")
local resolve = require("changeset.resolve")
local Fixture = require("support.git")
require("support.gh") -- a fake gh on PATH: never the real one, never the network

---Runs `fn`, keeping the argv of every process started through `vim.system` or `vim.fn.systemlist`.
---@param fn fun()
---@return string[][]
local function recording(fn)
  local argvs = {}
  local system, systemlist = vim.system, vim.fn.systemlist
  vim.system = function(argv, ...)
    argvs[#argvs + 1] = argv
    return system(argv, ...)
  end
  vim.fn.systemlist = function(argv, ...)
    argvs[#argvs + 1] = argv
    return systemlist(argv, ...)
  end
  local ok, err = pcall(fn)
  vim.system, vim.fn.systemlist = system, systemlist
  assert(ok, err)
  return argvs
end

---Each argv as one line, the repository and the fork point named rather than spelled, sorted:
---`diff.lua` starts its commands from a `pairs` loop, so their order is not stable.
---@param argvs string[][]
---@param tree changeset.Session
---@return string[]
local function normalized(argvs, tree)
  local lines = vim.tbl_map(function(argv)
    local line = table.concat(argv, " "):gsub(vim.pesc(tree.root), "<root>"):gsub(vim.pesc(tree.base), "<base>")
    return line
  end, argvs)
  table.sort(lines)
  return lines
end

local BUILD = {
  "gh pr view --json baseRefName,number,state",
  "git -C <root> merge-base <base> trunk",
  "git -C <root> merge-base HEAD trunk",
  "git -C <root> rev-parse --abbrev-ref HEAD",
  "git -C <root> rev-parse --verify --quiet main",
  "git -C <root> rev-parse --verify --quiet main",
  "git -C <root> rev-parse --verify --quiet master",
  "git -C <root> rev-parse --verify --quiet master",
  "git -C <root> rev-parse --verify --quiet origin/trunk",
  "git -C <root> rev-parse --verify --quiet trunk",
  "git -C <root> rev-parse --verify --quiet trunk",
  "git -C <root> rev-parse --verify --quiet trunk",
  "git -C <root> symbolic-ref --short refs/remotes/origin/HEAD",
  "git -C <root> symbolic-ref --short refs/remotes/origin/HEAD",
  "git -c core.quotepath=off diff --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ -M --name-status <base>",
  "git -c core.quotepath=off diff --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ -M --numstat <base>",
  "git -c core.quotepath=off diff --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ -M --unified=0 <base>",
  "git -c core.quotepath=off ls-files --others --exclude-standard",
  "git -c core.quotepath=off rev-list --count <base>..HEAD",
  "git check-attr -z --stdin linguist-generated",
}

local REFRESH = vim.list_slice(BUILD, #BUILD - 5)

describe("changeset.build", function()
  local tmp, previous_dir
  local real_start = resolve.start

  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    previous_dir = vim.fn.chdir(tmp)
    assert(previous_dir ~= "", "could not enter the fixture directory")
    Fixture.init_repo("trunk", tmp)
    vim.fn.writefile({ "return 1" }, "mod.lua")
    Fixture.commit("base", tmp)
    Fixture.git({ "checkout", "-q", "-b", "feature" }, tmp)
    vim.fn.writefile({ "return 2" }, "mod.lua")
    Fixture.commit("change", tmp)
    vim.cmd.edit("mod.lua")
    resolve.start = function()
      return function() end
    end
  end)

  after_each(function()
    resolve.start = real_start
    changeset.close()
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
  end)

  it("starts the same git and gh commands for a build and a refresh", function()
    local build_argvs = recording(function()
      assert.is_true(changeset.build())
      assert.is_true(vim.wait(10000, function()
        return (changeset._tree() or {}).collected
      end, 25))
    end)
    assert.same(BUILD, normalized(build_argvs, assert(changeset._tree())))

    local before = assert(changeset._tree()).files
    local refresh_argvs = recording(function()
      changeset.refresh()
      assert.is_true(vim.wait(10000, function()
        return changeset._tree().files ~= before
      end, 25))
    end)
    assert.same(REFRESH, normalized(refresh_argvs, assert(changeset._tree())))
  end)
end)
