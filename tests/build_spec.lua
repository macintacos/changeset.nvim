local build = require("changeset.build")
local resolve = require("changeset.resolve")
local Changes = require("support.changes")
local Fixture = require("support.git")
local Notify = require("support.notify")
local symbols = require("support.symbols")
local gh = require("support.gh") -- a fake gh on PATH: never the real one, never the network

---Every announcement the tree makes, in order; emptied before each case.
---@type changeset.TreeEvent[]
local events = {}
build.subscribe(function(event)
  events[#events + 1] = event
end)

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
  assert.is_true(build.build())
  assert.is_true(vim.wait(10000, function()
    return (build.current() or {}).collected
  end, 25))
end

describe("changeset.build", function()
  local tmp, previous_dir
  local source

  before_each(function()
    tmp, previous_dir = Fixture.enter_tempdir()
    Fixture.feature_one_file(tmp)
    vim.cmd.edit("mod.lua")
    events = {}
    source = symbols.install()
  end)

  after_each(function()
    source.restore()
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
  end)

  it("a refresh starts no merge-base, rev-parse or gh process", function()
    build_and_collect()
    assert.is_nil(package.loaded["changeset"])
    local before = assert(build.current()).files

    local argvs = recording(function()
      build.refresh()
      assert.is_true(vim.wait(10000, function()
        return build.current().files ~= before
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

  describe("while gh is slow to answer", function()
    before_each(function()
      vim.env.FAKE_GH_DELAY = "1"
    end)

    after_each(function()
      vim.env.FAKE_GH_DELAY = nil
    end)

    it("asks gh once when HEAD's fork point moves before it answers no PR", function()
      local argvs = recording(function()
        build_and_collect()
        Fixture.git({ "checkout", "-q", "trunk" }, tmp)
        Fixture.git({ "commit", "-q", "--allow-empty", "-m", "trunk work" }, tmp)
        Fixture.git({ "checkout", "-q", "feature" }, tmp)
        Fixture.git({ "rebase", "-q", "trunk" }, tmp)
        build_and_collect()
        -- Long enough for the first answer to land and anything it starts to ask gh again.
        vim.wait(3000, function()
          return false
        end, 25)
      end)

      local gh_asks = vim.tbl_filter(function(argv)
        return runs(argv, "gh")
      end, argvs)
      assert.equal(1, #gh_asks)
      assert.equal(Fixture.git({ "rev-parse", "trunk" }, tmp), build.current().base)
    end)
  end)

  describe("asking about symbols", function()
    local asked

    ---Answer every file with `items` and `comment_lines` at once, counting each time `path` is asked about.
    ---@param items table[]?
    ---@param comment_lines changeset.Comments?
    local function answer(items, comment_lines)
      asked = 0
      resolve.start = function(_, files, on_file)
        for _, file in ipairs(files) do
          asked = asked + (file.path == "mod.lua" and 1 or 0)
          on_file(file.path, items, comment_lines)
        end
        return function() end
      end
    end

    ---Refresh, waiting for the new diff.
    local function refresh_and_collect()
      local before = assert(build.current()).files
      build.refresh()
      assert.is_true(vim.wait(10000, function()
        return build.current().files ~= before
      end, 25))
    end

    it("writes what it read to the cache before building in another repository", function()
      answer({ Changes.sym("f", "Function", 0, 1, 1) })
      build_and_collect()
      local root = build.current().root
      local other = vim.fn.tempname()
      vim.fn.mkdir(other, "p")
      Fixture.feature_one_file(other)
      vim.cmd.edit(other .. "/mod.lua")

      build.build()

      local saved = require("changeset.cache").load(require("changeset.cache").path(root))
      vim.fn.delete(other, "rf")
      assert.is_truthy(saved["mod.lua"])
    end)

    it("keeps a file's symbols when an older walk reports it unanswered afterwards", function()
      build_and_collect()
      build.refresh()
      assert.is_true(vim.wait(10000, function()
        return #source.asks == 2
      end, 25))
      local items = { { name = "f", kind = "Function", depth = 0, lnum = 1, range_lnum = 1, range_end_lnum = 1 } }
      source.asks[2].answer("mod.lua", items)
      source.asks[1].answer("mod.lua", nil)

      refresh_and_collect()

      assert.equal(1, #assert(build.current().symbols["mod.lua"]))
    end)

    it("does not cache the symbols read from a buffer holding unwritten edits", function()
      answer({ Changes.sym("f", "Function", 0, 1, 1) })
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "return 3" })
      build_and_collect()

      refresh_and_collect()

      assert.equal(2, asked)
    end)

    it("keeps a file's comment lines across a refresh without asking about it again", function()
      local comment_lines = { new = { comment = { { 1, 1 } }, directive = {}, blank = {} } }
      answer({}, comment_lines)
      build_and_collect()

      refresh_and_collect()

      assert.equal(1, asked)
      assert.same(comment_lines, build.current().comments["mod.lua"])
    end)

    it("does not cache the comment lines read from a silent file's buffer holding unwritten edits", function()
      answer(nil, { new = { comment = { { 1, 1 } }, directive = {}, blank = {} } })
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "-- note", "return 3" })
      build_and_collect()

      refresh_and_collect()

      assert.equal(1, asked)
      assert.is_nil(build.current().comments["mod.lua"])
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

  describe("announcing", function()
    ---@param count integer
    local function wait_for_asks(count)
      assert.is_true(vim.wait(10000, function()
        return #source.asks == count
      end, 25))
    end

    it("announces the diff, then a file's symbols as they arrive", function()
      build.build()
      wait_for_asks(1)
      assert.same({ "diff" }, events)

      source.asks[1].answer("mod.lua", {})

      assert.same({ "diff", "symbols" }, events)
    end)

    it("stays silent for an answer to a refresh that a newer one replaced", function()
      build.build()
      wait_for_asks(1)
      build.refresh()
      wait_for_asks(2)
      events = {}

      source.asks[1].answer("mod.lua", {})

      assert.same({}, events)
    end)
  end)

  describe("once gh names a PR onto the branch already compared against", function()
    before_each(function()
      vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "trunk", number = 7 })
    end)

    after_each(function()
      vim.env.FAKE_GH_PR = nil
    end)

    it("announces the PR and keeps the tree", function()
      build_and_collect()
      local built = build.current()

      assert.is_true(vim.wait(10000, function()
        return vim.list_contains(events, "pr")
      end, 25))
      assert.equal(built, build.current())
    end)

    it("hears the PR while the current buffer is outside the tree's repository", function()
      vim.env.FAKE_GH_DELAY = "1"
      local elsewhere = vim.fn.tempname()
      vim.fn.mkdir(elsewhere, "p")
      build_and_collect()
      vim.fn.chdir(elsewhere)
      vim.cmd("enew")
      vim.bo.buftype = "nofile"

      local heard = vim.wait(5000, function()
        return vim.list_contains(events, "pr")
      end, 25)
      vim.env.FAKE_GH_DELAY = nil
      vim.fn.delete(elsewhere, "rf")
      assert.is_true(heard)
      assert.equal(7, build.current().pr)
    end)

    it("asks gh again once HEAD moves", function()
      build_and_collect()
      assert.is_true(vim.wait(10000, function()
        return vim.list_contains(events, "pr")
      end, 25))
      Fixture.git({ "commit", "-q", "--allow-empty", "-m", "more work" }, tmp)

      local argvs = recording(function()
        build.update()
        vim.wait(3000, function()
          return false
        end, 25)
      end)

      assert.equal(1, #vim.tbl_filter(function(argv)
        return runs(argv, "gh")
      end, argvs))
    end)
  end)

  describe("when the diff cannot be read", function()
    local diff = require("changeset.diff")
    local real_collect, restore_notify = diff.collect, nil

    before_each(function()
      diff.collect = function(_, _, on_done)
        on_done(nil, "boom")
      end
      _, restore_notify = Notify.capture()
    end)

    after_each(function()
      diff.collect = real_collect
      restore_notify()
    end)

    it("announces the failure", function()
      build.build()

      assert.same({ "failed" }, events)
    end)
  end)
end)
