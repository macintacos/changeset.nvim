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
    ---@param timed_out boolean?
    local function answer(items, comment_lines, timed_out)
      asked = 0
      resolve.start = function(_, files, on_file)
        for _, file in ipairs(files) do
          asked = asked + (file.path == "mod.lua" and 1 or 0)
          on_file(file.path, items, comment_lines, timed_out)
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

    it("shows the symbols an older walk filed when the current walk hears silence about the same file", function()
      build_and_collect()
      build.refresh()
      assert.is_true(vim.wait(10000, function()
        return #source.asks == 2
      end, 25))
      local items = { { name = "f", kind = "Function", depth = 0, lnum = 1, range_lnum = 1, range_end_lnum = 1 } }
      source.asks[1].answer("mod.lua", items)
      source.asks[2].answer("mod.lua", nil)

      assert.equal(1, #assert(build.current().symbols["mod.lua"]))
    end)

    it("asks again on the next refresh about a file whose server timed out", function()
      answer(nil, nil, true)
      build_and_collect()

      refresh_and_collect()

      assert.equal(2, asked)
    end)

    it("saves the symbols it filed to the cache once answers stop arriving", function()
      answer({ Changes.sym("f", "Function", 0, 1, 1) })
      build_and_collect()
      local cache = require("changeset.cache")
      local file = cache.path(build.current().root)

      assert.is_true(vim.wait(3000, function()
        return (cache.load(file)["mod.lua"] or {}).symbols ~= nil
      end, 50))
      assert.same(build.current().symbols["mod.lua"], cache.load(file)["mod.lua"].symbols)
    end)

    it("keeps each file and its symbols the same objects across a refresh over an unchanged diff", function()
      answer({ Changes.sym("f", "Function", 0, 1, 1) })
      build_and_collect()
      local tree = assert(build.current())
      local file, read = tree.files[1], tree.symbols["mod.lua"]

      refresh_and_collect()

      assert.equal(file, build.current().files[1])
      assert.equal(read, build.current().symbols["mod.lua"])
    end)

    it("hands a refresh a file of its own once its diff moves", function()
      build_and_collect()
      local file = assert(build.current()).files[1]
      vim.fn.writefile({ "local x = 4", "return x" }, "mod.lua")

      refresh_and_collect()

      assert.not_equal(file, build.current().files[1])
    end)

    it("hands a refresh a file of its own once a hunk moves with the same totals", function()
      vim.fn.writefile({ "return 1", "local added" }, "mod.lua")
      build_and_collect()
      local file = assert(build.current()).files[1]
      vim.fn.writefile({ "local added", "return 1" }, "mod.lua")

      refresh_and_collect()

      local moved = build.current().files[1]
      assert.same({ file.added, file.removed, #file.hunks }, { moved.added, moved.removed, #moved.hunks })
      assert.not_equal(file, moved)
    end)

    it("does not cache the symbols read from a buffer holding unwritten edits", function()
      answer({ Changes.sym("f", "Function", 0, 1, 1) })
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "return 3" })
      build_and_collect()

      refresh_and_collect()

      assert.equal(2, asked)
    end)

    it("finds the buffer holding unwritten edits by its name, without normalising every buffer's", function()
      vim.cmd("silent! %bwipeout!")
      -- Ahead of mod.lua's buffer in the list, the one left after the wipe included.
      vim.cmd.edit("filler0.lua")
      local fillers = { vim.api.nvim_get_current_buf() }
      for i = 1, 5 do
        fillers[i + 1] = vim.fn.bufadd(tmp .. "/filler" .. i .. ".lua")
        vim.fn.bufload(fillers[i + 1])
      end
      vim.cmd.edit("mod.lua")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "return 3" })
      local normalised, answering, real_normalize = {}, false, vim.fs.normalize
      vim.fs.normalize = function(path, ...)
        if answering then
          normalised[#normalised + 1] = path
        end
        return real_normalize(path, ...)
      end
      asked = 0
      resolve.start = function(_, files, on_file)
        answering = true
        for _, file in ipairs(files) do
          asked = asked + 1
          on_file(file.path, { Changes.sym("f", "Function", 0, 1, 1) })
        end
        answering = false
        return function() end
      end

      local ok, err = pcall(build_and_collect)
      vim.fs.normalize = real_normalize

      assert(ok, err)
      for _, buf in ipairs(fillers) do
        assert.is_false(vim.tbl_contains(normalised, vim.api.nvim_buf_get_name(buf)))
      end
      -- Found, so not cached: the refresh asks again.
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

    it("lists a file's symbols after the refresh that follows a server answering past the timeout", function()
      source.restore()
      -- A server still loading its project: the first answer is late, the ones after are not.
      local ANSWER_MS, loading, id = 300, true, 0
      vim.lsp.config("slow_symbols", {
        filetypes = { "lua" },
        root_dir = tmp,
        cmd = function(dispatchers)
          return {
            request = function(method, _, callback)
              local range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 8 } }
              local result = method == "initialize" and { capabilities = { documentSymbolProvider = true } }
                or method == "textDocument/documentSymbol" and {
                  { name = "f", kind = 12, range = range, selectionRange = range },
                }
                or vim.NIL
              local late = method == "textDocument/documentSymbol" and loading
              loading = loading and not late
              vim.defer_fn(function()
                callback(nil, result)
              end, late and ANSWER_MS or 0)
              id = id + 1
              return true, id
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
      vim.lsp.enable("slow_symbols")
      vim.cmd("silent! %bwipeout!")
      vim.cmd.edit("mod.lua")
      local real_defer = vim.defer_fn
      vim.defer_fn = function(fn, ms)
        return real_defer(fn, ms == 10000 and 100 or ms)
      end

      local ok, err = pcall(function()
        build_and_collect()
        assert.is_true(vim.wait(5000, function()
          return build.current().symbols["mod.lua"] ~= nil
        end, 10))
        vim.wait(2 * ANSWER_MS)
        build.refresh()
        vim.wait(1500, function()
          return #(build.current().symbols["mod.lua"] or {}) > 0
        end, 10)
      end)
      vim.defer_fn = real_defer
      vim.lsp.enable("slow_symbols", false)
      for _, client in ipairs(vim.lsp.get_clients({ name = "slow_symbols" })) do
        client:stop(true)
      end

      assert(ok, err)
      assert.equal(1, #(build.current().symbols["mod.lua"] or {}))
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
    local real_collect = diff.collect
    ---@type fun()
    local restore_notify

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

describe("changeset.build on a branch measured against its PR's target", function()
  local root, previous_dir, source, parent_base

  ---@param name string
  ---@return string
  local function commit_file(name)
    vim.fn.writefile({ name }, root .. "/" .. name)
    return Fixture.commit(name, root)
  end

  ---Build the tree, waiting for gh's PR to move it onto parent.
  local function build_on_pr()
    assert.is_true(build.build())
    assert.is_true(vim.wait(5000, function()
      local tree = build.current()
      return tree ~= nil and tree.pr == 7 and tree.collected
    end, 10))
    assert.equal(parent_base, build.current().base)
  end

  before_each(function()
    root = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(root, "p")
    Fixture.init_repo("main", root)
    commit_file("main.txt")
    Fixture.git({ "checkout", "-q", "-b", "parent" }, root)
    parent_base = commit_file("parent.txt")
    -- Created from a commit, as `gh pr checkout` leaves it: no parent branch in the reflog.
    Fixture.git({ "checkout", "-q", "-b", "feature", parent_base }, root)
    commit_file("feature.txt")
    previous_dir = vim.fn.getcwd()
    vim.fn.chdir(root)
    vim.cmd.edit("feature.txt")
    source = symbols.install()
    vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "parent", number = 7 })
  end)

  after_each(function()
    vim.env.FAKE_GH_PR = nil
    vim.env.FAKE_GH_DELAY = nil
    source.restore()
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(root, "rf")
  end)

  it("keeps the tree on the PR's target across a commit", function()
    build_on_pr()
    local kept = assert(build.current())
    vim.env.FAKE_GH_DELAY = "0.5"
    commit_file("more.txt")

    build.update()
    vim.wait(400)

    assert.equal(kept, build.current())
    assert.equal(parent_base, kept.base)
  end)

  it("measures a commit's fork point without blocking Neovim", function()
    build_on_pr()
    commit_file("more.txt")

    local waited, real_systemlist = {}, vim.fn.systemlist
    vim.fn.systemlist = function(argv, ...)
      waited[#waited + 1] = argv
      return real_systemlist(argv, ...)
    end
    local ok, err = pcall(build.update)
    vim.fn.systemlist = real_systemlist
    assert(ok, err)

    assert.same({}, waited)
  end)

  it("measures against the PR's target at once when switching back to the branch", function()
    build_on_pr()
    Fixture.git({ "switch", "-q", "parent" }, root)
    build.update()
    vim.env.FAKE_GH_DELAY = "0.5"
    Fixture.git({ "switch", "-q", "feature" }, root)

    build.update()

    assert.equal("feature", build.current().branch)
    assert.equal(parent_base, build.current().base)
  end)

  it("moves to the default branch once a commit finds the PR closed", function()
    build_on_pr()
    vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "parent", number = 7, state = "CLOSED" })
    commit_file("more.txt")

    build.update()

    assert.is_true(vim.wait(5000, function()
      local tree = assert(build.current())
      return tree.base ~= parent_base and tree.pr == nil
    end, 25))
  end)

  it("keeps the tree on the PR's target when gh fails after a commit", function()
    build_on_pr()
    -- gh exits non-zero offline, on its timeout, or with an expired login.
    vim.env.FAKE_GH_PR = ""
    commit_file("more.txt")

    build.update()
    vim.wait(1500)

    local tree = assert(build.current())
    assert.equal(parent_base, tree.base)
    assert.equal(7, tree.pr)
  end)
end)

describe("changeset.build after a rebase onto a moved default branch", function()
  local root, previous_dir, source

  ---@param name string
  ---@return string
  local function commit_file(name)
    vim.fn.writefile({ name }, root .. "/" .. name)
    return Fixture.commit(name, root)
  end

  before_each(function()
    root = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(root, "p")
    Fixture.init_repo("main", root)
    commit_file("main.txt")
    Fixture.git({ "checkout", "-q", "-b", "feature" }, root)
    commit_file("feature.txt")
    previous_dir = vim.fn.getcwd()
    vim.fn.chdir(root)
    vim.cmd.edit("feature.txt")
    source = symbols.install()
    vim.env.FAKE_GH_PR = ""
  end)

  after_each(function()
    vim.env.FAKE_GH_PR = nil
    source.restore()
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(root, "rf")
  end)

  it("never lists upstream's files as the branch's", function()
    build_and_collect()
    Fixture.git({ "checkout", "-q", "main" }, root)
    for i = 1, 30 do
      commit_file("upstream" .. i .. ".txt")
    end
    local new_base = Fixture.git({ "rev-parse", "HEAD" }, root)
    Fixture.git({ "checkout", "-q", "feature" }, root)
    Fixture.git({ "rebase", "-q", "main" }, root)
    local listed = {}
    build.subscribe(function(event)
      local tree = build.current()
      if event == "diff" and tree then
        for _, file in ipairs(tree.files) do
          listed[#listed + 1] = file.path
        end
      end
    end)

    build.update()

    assert.is_true(vim.wait(5000, function()
      local tree = build.current()
      return tree ~= nil and tree.base == new_base and tree.collected
    end, 10))
    vim.wait(300)
    assert.same(
      {},
      vim.tbl_filter(function(path)
        return vim.startswith(path, "upstream")
      end, listed)
    )
  end)
end)
