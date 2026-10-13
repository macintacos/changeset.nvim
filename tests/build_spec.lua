local Build = require("support.build")
local build = require("changeset.build")
local resolve = require("changeset.resolve")
local Changes = require("support.changes")
local Fixture = require("support.git")
local Notify = require("support.notify")
local symbols = require("support.symbols")
local gh = require("support.gh") -- a fake gh on PATH: never the real one, never the network
local present = require("support.present")
local spawns = require("support.spawns")

---Every announcement the tree makes, in order; emptied before each case.
---@type changeset.TreeEvent[]
local events = {}
build.subscribe(function(event)
  events[#events + 1] = event
end)

local recording, runs = spawns.recording, spawns.runs

---Build the tree, waiting for its diff.
local function build_and_collect()
  assert.equal("built", Build.build())
  assert.is_true(vim.wait(10000, function()
    return (build.current() or {}).collected
  end, 25))
end

describe("changeset.build", function()
  local tmp ---@type string
  local previous_dir ---@type string
  local source ---@type support.symbols.Source

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
    local before = present(build.current()).files

    local argvs = recording(function()
      build.refresh()
      assert.is_true(vim.wait(10000, function()
        return present(build.current()).files ~= before
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

  it("keeps and refreshes the tree after a switch to a branch with no fork point", function()
    build_and_collect()
    local kept = build.current()
    Fixture.git({ "checkout", "-q", "--orphan", "unrelated" }, tmp)
    Fixture.git({ "commit", "-q", "-m", "unrelated history" }, tmp)
    events = {}

    build.update()

    assert.equal(kept, build.current())
    assert.is_true(vim.wait(5000, function()
      return vim.list_contains(events, "diff")
    end, 10))
  end)

  it("measures the first build's fork point without a blocking git call", function()
    spawns.measures_unblocked(function()
      assert.equal("built", Build.build())
    end)
  end)

  it("rebuilds for a switched branch without a blocking git call", function()
    build_and_collect()
    Fixture.git({ "checkout", "-q", "-b", "feature2" }, tmp)

    local blocked = spawns.blocking(function()
      build.update()
      assert.is_true(vim.wait(10000, function()
        return present(build.current()).branch == "feature2"
      end, 10))
    end)

    for _, argv in ipairs(blocked) do
      assert.is_false(spawns.measuring(argv), table.concat(argv, " "))
    end
  end)

  it("an ask for another repository answers the replaced ask with replaced", function()
    local other = vim.fn.tempname()
    vim.fn.mkdir(other, "p")
    Fixture.feature_one_file(other)
    local heard = { first = {}, second = {} }

    build.build(function(outcome)
      table.insert(heard.first, { outcome })
    end)
    vim.cmd.edit(other .. "/mod.lua")
    build.build(function(outcome)
      table.insert(heard.second, { outcome })
    end)
    assert.is_true(vim.wait(10000, function()
      return #heard.second > 0
    end, 10))
    -- The replaced ask's measure is still running; give a stray second answer time to arrive.
    vim.wait(200)

    vim.fn.delete(other, "rf")
    assert.are.same({ { "replaced" } }, heard.first)
    assert.are.same({ { "built" } }, heard.second)
  end)

  it("lands an ask made while a build measures on a fork point measured after the ask", function()
    local first = Fixture.git({ "rev-parse", "HEAD" }, tmp)
    vim.fn.writefile({ "return 2" }, tmp .. "/second.lua")
    Fixture.commit("second", tmp)
    local fork_point = require("changeset.fork_point")
    local get_async = fork_point.get_async
    local held = {} ---@type fun()[]
    fork_point.get_async = function(root, branch, on_done)
      get_async(root, branch, function(point)
        held[#held + 1] = function()
          on_done(point)
        end
      end)
    end
    local landed = 0
    build.build(function()
      landed = landed + 1
    end)
    assert.is_true(vim.wait(10000, function()
      return #held > 0
    end, 10))
    fork_point.get_async = get_async

    Fixture.git({ "update-ref", "refs/heads/trunk", first }, tmp)
    build.build(function()
      landed = landed + 1
    end)
    present(held[1])()

    assert.is_true(vim.wait(10000, function()
      return landed == 2
    end, 10))
    assert.equal(first, present(build.current()).base)
  end)

  it("lands a build that asks keep joining while it measures", function()
    local fork_point = require("changeset.fork_point")
    local get_async = fork_point.get_async
    local measures = 0
    fork_point.get_async = function(root, branch, on_done)
      measures = measures + 1
      build.build(function() end)
      get_async(root, branch, on_done)
    end
    local landed
    build.build(function(outcome)
      landed = outcome
    end)

    local ok = vim.wait(10000, function()
      return landed ~= nil
    end, 10)
    fork_point.get_async = get_async
    assert.is_true(ok, "the build never landed")
    assert.equal("built", landed)
    assert.equal(3, measures)
  end)

  it("builds for the branch HEAD switched to while it measured", function()
    local fork_point = require("changeset.fork_point")
    local get_async, held = fork_point.get_async, {}
    fork_point.get_async = function(root, branch, on_done)
      held[#held + 1] = { root, branch, on_done }
    end
    local landed
    build.build(function(outcome)
      landed = outcome
    end)
    fork_point.get_async = get_async
    Fixture.git({ "checkout", "-q", "-b", "feature2" }, tmp)
    for _, args in ipairs(held) do
      get_async(args[1], args[2], args[3])
    end

    assert.is_true(vim.wait(10000, function()
      return landed ~= nil
    end, 10))
    assert.equal("built", landed)
    assert.equal("feature2", present(build.current()).branch)
  end)

  it("names the ref set by hand as its base when that ref forks where the base does", function()
    build_and_collect()
    Fixture.git({ "tag", "v1", "trunk" }, tmp)

    require("changeset.fork_point").pin(present(build.current()).root, "feature", "v1")

    assert.is_true(vim.wait(5000, function()
      return present(build.current()).ref == "v1"
    end, 10))
  end)

  describe("while gh is slow to answer", function()
    local held ---@type support.spawns.Held?

    after_each(function()
      if held then
        held.stop()
        held = nil
      end
    end)

    it("asks gh once when HEAD's fork point moves before it answers no PR", function()
      local argvs = recording(function()
        -- Held until HEAD's fork point has moved, however long moving it takes under load.
        held = spawns.holding(function(argv)
          return not runs(argv, "gh")
        end)
        build_and_collect()
        Fixture.git({ "checkout", "-q", "trunk" }, tmp)
        Fixture.git({ "commit", "-q", "--allow-empty", "-m", "trunk work" }, tmp)
        Fixture.git({ "checkout", "-q", "feature" }, tmp)
        Fixture.git({ "rebase", "-q", "trunk" }, tmp)
        build_and_collect()
        present(held).release()
        -- Long enough for the first answer to land and anything it starts to ask gh again.
        vim.wait(3000, function()
          return false
        end, 25)
      end)

      local gh_asks = vim.tbl_filter(function(argv)
        return runs(argv, "gh")
      end, argvs)
      assert.equal(1, #gh_asks)
      assert.equal(Fixture.git({ "rev-parse", "trunk" }, tmp), present(build.current()).base)
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
      local before = present(build.current()).files
      build.refresh()
      assert.is_true(vim.wait(10000, function()
        return present(build.current()).files ~= before
      end, 25))
    end

    it("writes what it read to the cache before building in another repository", function()
      answer({ Changes.sym("f", "Function", 0, 1, 1) })
      build_and_collect()
      local root = present(build.current()).root
      local other = vim.fn.tempname()
      vim.fn.mkdir(other, "p")
      Fixture.feature_one_file(other)
      vim.cmd.edit(other .. "/mod.lua")

      Build.build()

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
      present(source.asks[2]).answer("mod.lua", items)
      present(source.asks[1]).answer("mod.lua", nil)

      refresh_and_collect()

      assert.equal(1, #present(present(build.current()).symbols["mod.lua"]))
    end)

    it("shows the symbols an older walk filed when the current walk hears silence about the same file", function()
      build_and_collect()
      build.refresh()
      assert.is_true(vim.wait(10000, function()
        return #source.asks == 2
      end, 25))
      local items = { { name = "f", kind = "Function", depth = 0, lnum = 1, range_lnum = 1, range_end_lnum = 1 } }
      present(source.asks[1]).answer("mod.lua", items)
      present(source.asks[2]).answer("mod.lua", nil)

      assert.equal(1, #present(present(build.current()).symbols["mod.lua"]))
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
      local file = cache.path(present(build.current()).root)

      assert.is_true(vim.wait(3000, function()
        return (cache.load(file)["mod.lua"] or {}).symbols ~= nil
      end, 50))
      assert.same(present(build.current()).symbols["mod.lua"], cache.load(file)["mod.lua"].symbols)
    end)

    it("keeps each file and its symbols the same objects across a refresh over an unchanged diff", function()
      answer({ Changes.sym("f", "Function", 0, 1, 1) })
      build_and_collect()
      local tree = present(build.current())
      local file, read = tree.files[1], tree.symbols["mod.lua"]

      refresh_and_collect()

      assert.equal(file, present(build.current()).files[1])
      assert.equal(read, present(build.current()).symbols["mod.lua"])
    end)

    it("hands a refresh a file of its own once its diff moves", function()
      build_and_collect()
      local file = present(build.current()).files[1]
      vim.fn.writefile({ "local x = 4", "return x" }, "mod.lua")

      refresh_and_collect()

      assert.not_equal(file, present(build.current()).files[1])
    end)

    it("hands a refresh a file of its own once a hunk moves with the same totals", function()
      vim.fn.writefile({ "return 1", "local added" }, "mod.lua")
      build_and_collect()
      local file = present(present(build.current()).files[1])
      vim.fn.writefile({ "local added", "return 1" }, "mod.lua")

      refresh_and_collect()

      local moved = present(present(build.current()).files[1])
      assert.same({ file.added, file.removed, #file.hunks }, { moved.added, moved.removed, #moved.hunks })
      assert.not_equal(file, moved)
    end)

    it("hands a refresh a file of its own once a changed line's text changes with the same counts", function()
      build_and_collect()
      local file = present(present(build.current()).files[1])
      vim.fn.writefile({ "return 3" }, "mod.lua")

      refresh_and_collect()

      local edited = present(present(build.current()).files[1])
      assert.same({ file.added, file.removed, #file.hunks }, { edited.added, edited.removed, #edited.hunks })
      assert.not_equal(file, edited)
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

      assert.is_true(ok, tostring(err))
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
      assert.same(comment_lines, present(build.current()).comments["mod.lua"])
    end)

    it("does not cache the comment lines read from a silent file's buffer holding unwritten edits", function()
      answer(nil, { new = { comment = { { 1, 1 } }, directive = {}, blank = {} } })
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "-- note", "return 3" })
      build_and_collect()

      refresh_and_collect()

      assert.equal(1, asked)
      assert.is_nil(present(build.current()).comments["mod.lua"])
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
      present(vim.lsp.get_client_by_id(present(client))):stop(true)

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
          return present(build.current()).symbols["mod.lua"] ~= nil
        end, 10))
        vim.wait(2 * ANSWER_MS)
        build.refresh()
        vim.wait(1500, function()
          return #(present(build.current()).symbols["mod.lua"] or {}) > 0
        end, 10)
      end)
      vim.defer_fn = real_defer
      vim.lsp.enable("slow_symbols", false)
      for _, client in ipairs(vim.lsp.get_clients({ name = "slow_symbols" })) do
        client:stop(true)
      end

      assert.is_true(ok, tostring(err))
      assert.equal(1, #(present(build.current()).symbols["mod.lua"] or {}))
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
      Build.build()
      wait_for_asks(1)
      assert.same({ "diff" }, events)

      present(source.asks[1]).answer("mod.lua", {})

      assert.same({ "diff", "symbols" }, events)
    end)

    it("stays silent for an answer to a refresh that a newer one replaced", function()
      Build.build()
      wait_for_asks(1)
      build.refresh()
      wait_for_asks(2)
      events = {}

      present(source.asks[1]).answer("mod.lua", {})

      assert.same({}, events)
    end)
  end)

  describe("once gh names a PR onto the branch already compared against", function()
    local held ---@type support.spawns.Held?

    before_each(function()
      vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "trunk", number = 7 })
    end)

    after_each(function()
      if held then
        held.stop()
        held = nil
      end
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
      local elsewhere = vim.fn.tempname()
      vim.fn.mkdir(elsewhere, "p")
      -- Held until the current buffer has left the tree's repository.
      held = spawns.holding(function(argv)
        return not runs(argv, "gh")
      end)
      build_and_collect()
      vim.fn.chdir(elsewhere)
      vim.cmd("enew")
      vim.bo.buftype = "nofile"
      present(held).release()

      local heard = vim.wait(5000, function()
        return vim.list_contains(events, "pr")
      end, 25)
      vim.fn.delete(elsewhere, "rf")
      assert.is_true(heard)
      assert.equal(7, present(build.current()).pr)
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
      Build.build()

      assert.same({ "failed" }, events)
    end)
  end)
end)

describe("changeset.build on a branch measured against its PR's target", function()
  local root ---@type string
  local previous_dir ---@type string
  local source ---@type support.symbols.Source
  local parent_base ---@type string
  local held ---@type support.spawns.Held?

  ---@param name string
  ---@return string
  local function commit_file(name)
    vim.fn.writefile({ name }, root .. "/" .. name)
    return Fixture.commit(name, root)
  end

  ---Build the tree, waiting for gh's PR to move it onto parent.
  local function build_on_pr()
    assert.equal("built", Build.build())
    assert.is_true(vim.wait(5000, function()
      local tree = build.current()
      return tree ~= nil and tree.pr == 7 and tree.collected
    end, 10))
    assert.equal(parent_base, present(build.current()).base)
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
    if held then
      held.stop()
      held = nil
    end
    vim.env.FAKE_GH_PR = nil
    source.restore()
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(root, "rf")
  end)

  it("keeps the tree on the PR's target across a commit", function()
    build_on_pr()
    local kept = present(build.current())
    -- Held, so the re-measure lands while gh is still being asked again.
    held = spawns.holding(function(argv)
      return not runs(argv, "gh")
    end)
    local head = commit_file("more.txt")

    build.update()
    assert.is_true(vim.wait(5000, function()
      return (build.current() or {}).head == head
    end, 10))

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
    assert.is_true(ok, tostring(err))

    assert.same({}, waited)
  end)

  it("measures against the PR's target at once when switching back to the branch", function()
    build_on_pr()
    -- Held, so the switch back can measure only from the target gh named before.
    held = spawns.holding(function(argv)
      return not runs(argv, "gh")
    end)
    Fixture.git({ "switch", "-q", "parent" }, root)
    build.update()
    assert.is_true(vim.wait(5000, function()
      return (build.current() or {}).branch == "parent"
    end, 10))
    Fixture.git({ "switch", "-q", "feature" }, root)

    build.update()
    assert.is_true(vim.wait(5000, function()
      return (build.current() or {}).branch == "feature"
    end, 10))

    assert.equal(parent_base, present(build.current()).base)
  end)

  it("moves to the default branch once a commit finds the PR closed", function()
    build_on_pr()
    vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "parent", number = 7, state = "CLOSED" })
    commit_file("more.txt")

    build.update()

    assert.is_true(vim.wait(5000, function()
      local tree = present(build.current())
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

    local tree = present(build.current())
    assert.equal(parent_base, tree.base)
    assert.equal(7, tree.pr)
  end)
end)

describe("changeset.build after a rebase onto a moved default branch", function()
  local root ---@type string
  local previous_dir ---@type string
  local source ---@type support.symbols.Source

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
