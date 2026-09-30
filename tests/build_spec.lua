local changeset = require("changeset")
local resolve = require("changeset.resolve")
local Fixture = require("support.git")
require("support.gh") -- a fake gh on PATH: never the real one, never the network

---Runs `fn`, keeping the argv of every process started through `vim.system` or `vim.fn.systemlist`.
---@param fn fun()
---@return string[][]
local function recording(fn)
  local argvs = {}
  local real_system, real_systemlist = vim.system, vim.fn.systemlist
  vim.system = function(argv, ...)
    argvs[#argvs + 1] = argv
    return real_system(argv, ...)
  end
  vim.fn.systemlist = function(argv, ...)
    argvs[#argvs + 1] = argv
    return real_systemlist(argv, ...)
  end
  local ok, err = pcall(fn)
  vim.system, vim.fn.systemlist = real_system, real_systemlist
  assert(ok, err)
  return argvs
end

---Whether `argv` starts `program` with `subcommand`, as `git -C <root> merge-base …` starts git's merge-base.
---@param argv string[]
---@param program string
---@param subcommand string?
---@return boolean
local function runs(argv, program, subcommand)
  return argv[1] == program and (subcommand == nil or vim.list_contains(argv, subcommand))
end

---Build the tree, waiting for its diff.
local function build_and_collect()
  assert.is_true(changeset.build())
  assert.is_true(vim.wait(10000, function()
    return (changeset._tree() or {}).collected
  end, 25))
end

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

  -- Each wait stays inside `recording`: `check-attr` starts from a scheduled callback, after `build()` returns.

  it("a refresh starts no merge-base, rev-parse or gh process", function()
    build_and_collect()
    local before = assert(changeset._tree()).files

    local argvs = recording(function()
      changeset.refresh()
      assert.is_true(vim.wait(10000, function()
        return changeset._tree().files ~= before
      end, 25))
    end)

    assert.is_true(#argvs > 0)
    for _, argv in ipairs(argvs) do
      local line = table.concat(argv, " ")
      assert.is_false(runs(argv, "git", "merge-base"), line)
      assert.is_false(runs(argv, "git", "rev-parse"), line)
      assert.is_false(runs(argv, "gh"), line)
    end
  end)

  it("a build asks gh once", function()
    local argvs = recording(build_and_collect)

    assert.equal(1, #vim.tbl_filter(function(argv)
      return runs(argv, "gh")
    end, argvs))
  end)
end)
