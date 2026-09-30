local changeset = require("changeset")
local resolve = require("changeset.resolve")
local Fixture = require("support.git")
require("support.gh") -- a fake gh on PATH: never the real one, never the network

---Runs `fn`, keeping the argv of every process started through `vim.system` or `vim.fn.systemlist`.
---A wait belongs inside `fn`: `check-attr` starts from a scheduled callback, after `build()` returns.
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

  describe("asking about symbols", function()
    local asked

    ---Answer every file with `items` and `found` at once, counting each time `path` is asked about.
    ---@param items table[]?
    ---@param found changeset.Comments?
    local function answer(items, found)
      asked = 0
      resolve.start = function(_, files, on_file)
        for _, file in ipairs(files) do
          asked = asked + (file.path == "mod.lua" and 1 or 0)
          on_file(file.path, items, found)
        end
        return function() end
      end
    end

    ---Refresh, waiting for the new diff.
    local function refresh_and_collect()
      local before = assert(changeset._tree()).files
      changeset.refresh()
      assert.is_true(vim.wait(10000, function()
        return changeset._tree().files ~= before
      end, 25))
    end

    it("does not cache the symbols read from a buffer holding unwritten edits", function()
      answer({ { name = "f", kind = "Function", depth = 0, lnum = 1, range_lnum = 1, range_end_lnum = 1 } })
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "return 3" })
      build_and_collect()

      refresh_and_collect()

      assert.equal(2, asked)
    end)

    it("keeps a file's comment lines across a refresh without asking about it again", function()
      local found = { new = { comment = { { 1, 1 } }, directive = {}, blank = {} } }
      answer({}, found)
      build_and_collect()

      refresh_and_collect()

      assert.equal(1, asked)
      assert.same(found, changeset._tree().comments["mod.lua"])
    end)

    it("does not cache the comment lines read from a silent file's buffer holding unwritten edits", function()
      answer(nil, { new = { comment = { { 1, 1 } }, directive = {}, blank = {} } })
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "-- note", "return 3" })
      build_and_collect()

      refresh_and_collect()

      assert.equal(1, asked)
      assert.is_nil(changeset._tree().comments["mod.lua"])
    end)

    it("asks again about a silent file once a symbol-listing server attaches to it", function()
      answer(nil)
      build_and_collect()

      local client = vim.lsp.start({
        name = "stub_symbols",
        cmd = function(dispatchers)
          return {
            request = function(method, _, callback)
              local result = method == "initialize" and { capabilities = { documentSymbolProvider = true } } or {}
              vim.schedule(function()
                callback(nil, result)
              end)
              return true, 1
            end,
            notify = function() end,
            is_closing = function()
              return false
            end,
            terminate = function()
              dispatchers.on_exit(0, 15)
            end,
          }
        end,
      })

      local reasked = vim.wait(10000, function()
        return asked == 2
      end, 25)
      assert(vim.lsp.get_client_by_id(assert(client))):stop(true)

      assert.is_true(reasked)
    end)
  end)
end)
