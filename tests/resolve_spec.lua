local comments = require("changeset.comments")
local Fixture = require("support.git")
local resolve = require("changeset.resolve")

---A step that parks each call so the spec decides when it answers.
---@return fun(path: string, done: fun(items: changeset.Symbol[]?, comments: changeset.Comments?)) run
---@return table[] pending
local function deferred()
  local pending = {}
  return function(path, done)
    pending[#pending + 1] = { path = path, done = done }
  end, pending
end

describe("changeset.resolve", function()
  describe("_walk", function()
    ---@return string[]
    local function ten_files()
      local queue = {}
      for i = 1, 10 do
        queue[i] = i .. ".ts"
      end
      return queue
    end

    it("starts files in the order given, so the tree fills top-down", function()
      local run, pending = deferred()

      resolve._walk({ "api.ts", "auth.ts" }, run, function() end)

      assert.same(
        { "api.ts", "auth.ts" },
        vim.tbl_map(function(call)
          return call.path
        end, pending)
      )
    end)

    it("reads a few files at a time, starting one more as each finishes", function()
      local run, pending = deferred()
      local queue = ten_files()

      resolve._walk(queue, run, function() end)
      local lanes = #pending
      assert.is_true(lanes > 0 and lanes < #queue)

      pending[1].done({})
      assert.equal(lanes + 1, #pending)
    end)

    it("still reports a file it was already reading when cancelled", function()
      local run, pending = deferred()
      local seen = {}

      local cancel = resolve._walk({ "api.ts", "auth.ts" }, run, function(path)
        seen[#seen + 1] = path
      end)
      cancel()
      pending[1].done({})

      assert.same({ "api.ts" }, seen)
    end)

    it("starts no further file once cancelled", function()
      local run, pending = deferred()

      local cancel = resolve._walk(ten_files(), run, function() end)
      local lanes = #pending
      cancel()
      pending[1].done({})

      assert.equal(lanes, #pending)
    end)

    it("keeps walking past a file its step had no symbols for", function()
      local run, pending = deferred()
      local seen = {}

      resolve._walk(ten_files(), run, function(path, items)
        seen[#seen + 1] = { path = path, items = items }
      end)
      local lanes = #pending
      pending[1].done(nil)

      assert.equal(1, #seen)
      assert.equal("1.ts", seen[1].path)
      assert.is_nil(seen[1].items)
      assert.equal(lanes + 1, #pending)
    end)

    it("reports a file whose step raised, rather than stranding its lane", function()
      local seen = {}

      resolve._walk({ "api.ts" }, function()
        error("no client")
      end, function(path, items)
        seen[#seen + 1] = { path = path, items = items }
      end)

      assert.equal(1, #seen)
      assert.equal("api.ts", seen[1].path)
      assert.is_nil(seen[1].items)
    end)

    it("reports the very table its step answered with", function()
      local run, pending = deferred()
      local answers = {}

      resolve._walk({ "api.ts" }, run, function(path, items)
        answers[path] = items
      end)
      local items = {}
      pending[1].done(items)

      assert.equal(items, answers["api.ts"])
    end)

    it("reports the comments its step answered with", function()
      local run, pending = deferred()
      local answers = {}

      resolve._walk({ "api.ts" }, run, function(path, _, found)
        answers[path] = found
      end)
      local found = { new = { comment = {}, directive = {}, blank = {} } }
      pending[1].done(nil, found)

      assert.equal(found, answers["api.ts"])
    end)

    it("reports a file once when its step answers and then raises", function()
      local seen = {}

      resolve._walk({ "api.ts", "auth.ts" }, function(_, done)
        done({})
        error("client vanished")
      end, function(path)
        seen[#seen + 1] = path
      end)

      assert.same({ "api.ts", "auth.ts" }, seen)
    end)
  end)

  describe("start", function()
    local root, enabled

    before_each(function()
      root = vim.fn.tempname()
      vim.fn.mkdir(root, "p")
      vim.fn.writefile({ "return {}" }, root .. "/mod.lua")
    end)

    after_each(function()
      if enabled then
        vim.lsp.enable(enabled, false)
        enabled = nil
      end
      vim.cmd("silent! %bwipeout!")
      vim.fn.delete(root, "rf")
    end)

    -- "added": a modified file reads its base first, which would put these waits behind a git call.
    ---Resolve `mod.lua`, returning the paths reported before `start` returned.
    ---@return string[]
    local function reported_at_once()
      local seen = {}
      local file = { path = "mod.lua", status = "added", added = 1, removed = 0, hunks = {} }
      local cancel = resolve.start({ root = root, base = "HEAD" }, { file }, function(path)
        seen[#seen + 1] = path
      end)
      cancel()
      return seen
    end

    it("reports a file no enabled server covers without waiting for one to attach", function()
      assert.same({ "mod.lua" }, reported_at_once())
    end)

    for _, case in ipairs({
      { name = "stub_lua", covers = "its filetype", filetypes = { "lua" } },
      { name = "stub_any", covers = "every filetype" },
    }) do
      it("waits on a server enabled for " .. case.covers, function()
        -- A root_dir that never answers keeps the server enabled but never started.
        vim.lsp.config(case.name, { cmd = function() end, filetypes = case.filetypes, root_dir = function() end })
        vim.lsp.enable(case.name)
        enabled = case.name

        assert.same({}, reported_at_once())
      end)
    end

    it("reports a file as unanswered once an enabled server fails to attach in time", function()
      vim.lsp.config("stub_lua", { cmd = function() end, filetypes = { "lua" }, root_dir = function() end })
      vim.lsp.enable("stub_lua")
      enabled = "stub_lua"
      local report
      local file = { path = "mod.lua", status = "added", added = 1, removed = 0, hunks = {} }

      resolve.start({ root = root, base = "HEAD" }, { file }, function(_, items)
        report = { items = items }
      end)

      assert.is_true(vim.wait(5000, function()
        return report ~= nil
      end, 25))
      assert.is_nil(report.items)
    end)

    it("waits past a client that lists no symbols for one that does", function()
      vim.lsp.config("stub_lua", { cmd = function() end, filetypes = { "lua" }, root_dir = function() end })
      vim.lsp.enable("stub_lua")
      enabled = "stub_lua"
      ---Attach `buf` to an in-process server named `name` that answers each method from `answers`.
      ---@param buf integer
      ---@param name string
      ---@param answers table<string, table>
      local function attach(buf, name, answers)
        vim.lsp.start({
          name = name,
          root_dir = root,
          cmd = function(dispatchers)
            return {
              request = function(method, _, callback)
                vim.schedule(function()
                  callback(nil, answers[method])
                end)
                return true, 1
              end,
              notify = function(method)
                if method == "exit" then
                  dispatchers.on_exit(0, 15)
                end
                return true
              end,
              is_closing = function()
                return false
              end,
              terminate = function() end,
            }
          end,
        }, { bufnr = buf })
      end
      local report
      local file = { path = "mod.lua", status = "added", added = 1, removed = 0, hunks = {} }
      resolve.start({ root = root, base = "HEAD" }, { file }, function(_, items)
        report = { items = items }
      end)
      local buf = vim.fn.bufnr(root .. "/mod.lua")

      attach(buf, "hover_only", { initialize = { capabilities = { hoverProvider = true } } })
      vim.wait(100)
      assert.is_nil(report)

      local range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 9 } }
      attach(buf, "symbols", {
        initialize = { capabilities = { documentSymbolProvider = true } },
        ["textDocument/documentSymbol"] = { { name = "one", kind = 12, range = range, selectionRange = range } },
      })
      assert.is_true(vim.wait(1000, function()
        return report ~= nil
      end, 25))
      assert.are.equal("one", assert(report.items)[1].name)
      for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
        client:stop()
      end
    end)

    ---Enable an in-process server for `filetype` that answers `symbols` for every file.
    ---@param name string
    ---@param filetype string
    ---@param symbols table[] LSP DocumentSymbols.
    local function serve(name, filetype, symbols)
      local answers = {
        initialize = { capabilities = { documentSymbolProvider = true } },
        ["textDocument/documentSymbol"] = symbols,
      }
      vim.lsp.config(name, {
        filetypes = { filetype },
        root_dir = root,
        cmd = function()
          return {
            request = function(method, _, callback)
              vim.schedule(function()
                callback(nil, answers[method])
              end)
              return true, 1
            end,
            notify = function() end,
            is_closing = function()
              return false
            end,
            terminate = function() end,
          }
        end,
      })
      vim.lsp.enable(name)
      enabled = name
    end

    ---@param name_line integer 0-based
    ---@param first_line integer 0-based line the range starts on
    local function fn_symbol(name, name_line, first_line)
      return {
        name = name,
        kind = 12,
        range = { start = { line = first_line, character = 0 }, ["end"] = { line = name_line, character = 20 } },
        selectionRange = {
          start = { line = name_line, character = 3 },
          ["end"] = { line = name_line, character = 3 + #name },
        },
      }
    end

    ---Resolve `path` and wait for its answer.
    ---@return table<string, { test: true? }>? by name
    local function resolved(path)
      local answer, done
      resolve.start(
        { root = root, base = "HEAD" },
        { { path = path, status = "added", section = "implementation", added = 1, removed = 0, hunks = {} } },
        function(_, items)
          answer, done = items, true
        end
      )
      vim.wait(2000, function()
        return done
      end)
      if not answer then
        return nil
      end
      local by_name = {}
      for _, item in ipairs(answer) do
        by_name[item.name] = item
      end
      return by_name
    end

    it("reports a file as unanswered when its buffer is wiped while its base is read", function()
      Fixture.init_repo("trunk", root)
      Fixture.commit("base", root)
      vim.fn.writefile({ "return { 1 }" }, root .. "/mod.lua")
      local report
      local file = { path = "mod.lua", status = "modified", added = 1, removed = 1, hunks = {} }

      resolve.start({ root = root, base = "HEAD" }, { file }, function(_, items)
        report = { items = items }
      end)
      vim.cmd("silent! %bwipeout!")

      assert.is_true(vim.wait(5000, function()
        return report ~= nil
      end, 25))
      assert.is_nil(report.items)
    end)

    it("reads a file's comment lines at its base and now when no server covers it", function()
      Fixture.init_repo("trunk", root)
      vim.fn.writefile({ "x = 1", "# old note" }, root .. "/conf.toml")
      Fixture.commit("base", root)
      vim.fn.writefile({ "# new note", "x = 1" }, root .. "/conf.toml")
      local report
      local file = { path = "conf.toml", status = "modified", added = 1, removed = 1, hunks = {} }

      resolve.start({ root = root, base = "HEAD" }, { file }, function(_, items, found)
        report = { items = items, comments = found }
      end)

      assert.is_true(vim.wait(5000, function()
        return report ~= nil
      end, 25))
      assert.is_nil(report.items)
      local found = assert(report.comments)
      assert.same({ "comment", "code" }, { comments.kind(found.new, 1), comments.kind(found.new, 2) })
      assert.same({ "code", "comment" }, { comments.kind(assert(found.old), 1), comments.kind(found.old, 2) })
    end)

    it("reads no comment lines for a Docs file, whose rows never split out comments", function()
      Fixture.init_repo("trunk", root)
      vim.fn.writefile({ "# Title" }, root .. "/README.md")
      Fixture.commit("base", root)
      vim.fn.writefile({ "# Title", "<!-- note -->" }, root .. "/README.md")
      local report
      local file = { path = "README.md", status = "modified", section = "docs", added = 1, removed = 0, hunks = {} }

      resolve.start({ root = root, base = "HEAD" }, { file }, function(_, items, found)
        report = { items = items, comments = found }
      end)

      assert.is_true(vim.wait(5000, function()
        return report ~= nil
      end, 25))
      assert.is_nil(report.comments)
    end)

    it("marks a test its attribute names in a file no one opened", function()
      serve("stub_rust", "rust", { fn_symbol("refreshes_token", 1, 0), fn_symbol("load", 2, 2) })
      vim.fn.mkdir(root .. "/src", "p")
      vim.fn.writefile({ "#[test]", "fn refreshes_token() {}", "fn load() {}" }, root .. "/src/session.rs")

      local items = assert(resolved("src/session.rs"))

      assert.is_true(items.refreshes_token.test)
      assert.is_nil(items.load.test)
    end)

    it("parses a TypeScript file's text once for its comment lines and its tests", function()
      serve("stub_ts", "typescript", { fn_symbol("load", 3, 3) })
      vim.fn.writefile({
        "// note",
        "if (import.meta.vitest) {",
        "}",
        "function load() {}",
      }, root .. "/api.ts")
      local real, parsed = vim.treesitter.get_string_parser, 0
      vim.treesitter.get_string_parser = function(...)
        parsed = parsed + 1
        return real(...)
      end

      local items = resolved("api.ts")
      vim.treesitter.get_string_parser = real

      assert.truthy(items and items.load)
      assert.equal(1, parsed)
    end)

    it("marks by the text the server read, unwritten edits included", function()
      serve("stub_rust", "rust", { fn_symbol("refreshes_token", 1, 0), fn_symbol("load", 2, 2) })
      vim.fn.mkdir(root .. "/src", "p")
      local path = root .. "/src/session.rs"
      vim.fn.writefile({ "fn refreshes_token() {}", "fn load() {}" }, path)
      local buf = vim.fn.bufadd(path)
      vim.fn.bufload(buf)
      vim.bo[buf].filetype = "rust"
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "#[test]" })

      local items = assert(resolved("src/session.rs"))

      assert.is_true(items.refreshes_token.test)
    end)
  end)

  describe("start, with servers that misbehave", function()
    local SYMBOL = {
      name = "one",
      kind = 12,
      range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 9 } },
      selectionRange = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 3 } },
    }

    local root, enabled

    before_each(function()
      root = vim.fn.tempname()
      vim.fn.mkdir(root, "p")
      vim.fn.writefile({ "return {}" }, root .. "/mod.lua")
    end)

    after_each(function()
      for _, client in ipairs(vim.lsp.get_clients()) do
        client:stop(true)
      end
      if enabled then
        vim.lsp.enable(enabled, false)
        enabled = nil
      end
      vim.cmd("silent! %bwipeout!")
      vim.fn.delete(root, "rf")
    end)

    ---An in-process server; `on_request(method, callback)` answers each request.
    local function server(on_request)
      return function(dispatchers)
        local id = 0
        return {
          request = function(method, params, callback)
            id = id + 1
            return on_request(method, callback, params) ~= false, id
          end,
          notify = function(method)
            if method == "exit" then
              dispatchers.on_exit(0, 15)
            end
            return true
          end,
          is_closing = function()
            return false
          end,
          terminate = function()
            dispatchers.on_exit(0, 15)
          end,
        }
      end
    end

    local function enable(name, cmd)
      vim.lsp.config(name, { filetypes = { "lua" }, root_dir = root, cmd = cmd })
      vim.lsp.enable(name)
      enabled = name
    end

    local function start(on_file)
      local file =
        { path = "mod.lua", status = "added", section = "implementation", added = 1, removed = 0, hunks = {} }
      return resolve.start({ root = root, base = "HEAD" }, { file }, on_file)
    end

    it("reports no answer, not an empty one, when the only server answers with an error", function()
      enable(
        "erroring",
        server(function(method, callback)
          vim.schedule(function()
            if method == "initialize" then
              callback(nil, { capabilities = { documentSymbolProvider = true } })
            elseif method == "textDocument/documentSymbol" then
              callback({ code = -32801, message = "content modified" }, nil)
            else
              callback(nil, nil)
            end
          end)
        end)
      )
      local report
      start(function(_, items)
        report = { items = items }
      end)
      assert.is_true(vim.wait(3000, function()
        return report ~= nil
      end, 20))
      assert.is_nil(report.items)
    end)

    ---Answers `initialize`, then hands each symbol request to `on_symbols(callback)`.
    local function symbol_server(on_symbols)
      return server(function(method, callback)
        if method == "textDocument/documentSymbol" then
          return on_symbols(callback)
        end
        vim.schedule(function()
          callback(nil, method == "initialize" and { capabilities = { documentSymbolProvider = true } } or nil)
        end)
      end)
    end

    it("reports a server that outlasts the request timeout as timed out, not as answering nothing", function()
      enable("silent_server", symbol_server(function() end))
      local real_defer = vim.defer_fn
      vim.defer_fn = function(fn, ms)
        return real_defer(fn, ms == 10000 and 50 or ms)
      end
      local report
      start(function(_, items, _, timed_out)
        report = { items = items, timed_out = timed_out }
      end)
      local landed = vim.wait(3000, function()
        return report ~= nil
      end, 20)
      vim.defer_fn = real_defer

      assert.is_true(landed)
      assert.is_nil(report.items)
      assert.is_true(report.timed_out)
    end)

    it("reports the file when its server exits before answering", function()
      local asked = false
      enable(
        "dies",
        server(function(method, callback)
          if method == "initialize" then
            vim.schedule(function()
              callback(nil, { capabilities = { documentSymbolProvider = true } })
            end)
          elseif method == "textDocument/documentSymbol" then
            asked = true
          else
            vim.schedule(function()
              callback(nil, nil)
            end)
          end
        end)
      )
      local report
      start(function(_, items)
        report = { items = items }
      end)
      assert.is_true(vim.wait(3000, function()
        return asked
      end, 20))
      for _, client in ipairs(vim.lsp.get_clients({ name = "dies" })) do
        client:stop(true)
      end
      assert.is_true(vim.wait(5000, function()
        return report ~= nil
      end, 20))
    end)

    it("still hears a server attach in time when a second walk waits on the same file", function()
      enable(
        "slow_start",
        server(function(method, callback)
          local delay = method == "initialize" and 400 or 0
          vim.defer_fn(function()
            if method == "initialize" then
              callback(nil, { capabilities = { documentSymbolProvider = true } })
            elseif method == "textDocument/documentSymbol" then
              callback(nil, { SYMBOL })
            else
              callback(nil, nil)
            end
          end, delay)
        end)
      )
      local first, second
      local cancel = start(function(_, items)
        first = { items = items }
      end)
      cancel()
      start(function(_, items)
        second = { items = items }
      end)
      assert.is_true(vim.wait(4000, function()
        return first ~= nil and second ~= nil
      end, 20))
      assert.truthy(second.items)
      assert.truthy(first.items, "the first walk timed out although the server attached in time")
    end)

    it("answers when a second symbol server attaches while the first is still answering", function()
      local respond
      enable(
        "first_server",
        server(function(method, callback)
          if method == "textDocument/documentSymbol" then
            respond = function()
              callback(nil, { SYMBOL })
            end
            return
          end
          vim.schedule(function()
            callback(nil, method == "initialize" and { capabilities = { documentSymbolProvider = true } } or nil)
          end)
        end)
      )
      local report
      start(function(_, items)
        report = { items = items }
      end)
      assert.is_true(vim.wait(3000, function()
        return respond ~= nil
      end, 20))
      local buf = vim.fn.bufnr(root .. "/mod.lua")
      vim.lsp.start({
        name = "second_server",
        root_dir = root,
        cmd = server(function(method, callback)
          vim.schedule(function()
            callback(nil, method == "initialize" and { capabilities = { documentSymbolProvider = true } } or {})
          end)
        end),
      }, { bufnr = buf })
      assert.is_true(vim.wait(2000, function()
        return #vim.lsp.get_clients({ bufnr = buf, method = "textDocument/documentSymbol" }) == 2
      end, 20))
      respond()
      assert.is_true(
        vim.wait(3000, function()
          return report ~= nil
        end, 20),
        "buf_request_all counted the late client, which was never asked, so it never answered"
      )
    end)

    it("reports a later server's symbols when an earlier one answers with none", function()
      local function answering_with(symbols)
        return function(method, callback)
          vim.schedule(function()
            if method == "initialize" then
              callback(nil, { capabilities = { documentSymbolProvider = true } })
            else
              callback(nil, method == "textDocument/documentSymbol" and symbols or nil)
            end
          end)
        end
      end
      enable("first_server", server(answering_with({})))
      local buf = vim.fn.bufadd(root .. "/mod.lua")
      vim.fn.bufload(buf)
      vim.bo[buf].filetype = "lua"
      vim.lsp.start(
        { name = "second_server", root_dir = root, cmd = server(answering_with({ SYMBOL })) },
        { bufnr = buf }
      )
      assert.is_true(vim.wait(2000, function()
        return #vim.lsp.get_clients({ bufnr = buf, method = "textDocument/documentSymbol" }) == 2
      end, 20))
      local report
      start(function(_, items)
        report = { items = items }
      end)
      assert.is_true(vim.wait(3000, function()
        return report ~= nil
      end, 20))
      assert.same(
        { "one" },
        vim.tbl_map(function(item)
          return item.name
        end, assert(report.items))
      )
    end)

    it("lists a symbol once when two servers both answer for the file", function()
      local function answering(method, callback)
        vim.schedule(function()
          if method == "initialize" then
            callback(nil, { capabilities = { documentSymbolProvider = true } })
          elseif method == "textDocument/documentSymbol" then
            callback(nil, { SYMBOL })
          else
            callback(nil, nil)
          end
        end)
      end
      enable("first_server", server(answering))
      local buf = vim.fn.bufadd(root .. "/mod.lua")
      vim.fn.bufload(buf)
      vim.bo[buf].filetype = "lua"
      vim.lsp.start({ name = "second_server", root_dir = root, cmd = server(answering) }, { bufnr = buf })
      assert.is_true(vim.wait(2000, function()
        return #vim.lsp.get_clients({ bufnr = buf, method = "textDocument/documentSymbol" }) == 2
      end, 20))
      local report
      start(function(_, items)
        report = { items = items }
      end)
      assert.is_true(vim.wait(3000, function()
        return report ~= nil
      end, 20))
      assert.equal(1, #assert(report.items))
    end)
  end)

  describe("start, on a file edited while its text parses", function()
    local tmp, previous_dir, real_parser

    ---documentSymbol from the buffer as it stands when asked: a Function per `local function`.
    local function symbols_for(buf)
      local out, open = {}, nil
      for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        local name = line:match("^local function ([%w_]+)")
        if name then
          open = { name = name, start = i - 1 }
        elseif open and line == "end" then
          local range = { start = { line = open.start, character = 0 }, ["end"] = { line = i - 1, character = 3 } }
          out[#out + 1] = { name = open.name, kind = 12, range = range, selectionRange = range }
          open = nil
        end
      end
      return out
    end

    local function live_server(dispatchers)
      local id = 0
      return {
        request = function(method, params, callback)
          id = id + 1
          local result = vim.NIL
          if method == "initialize" then
            result = { capabilities = { documentSymbolProvider = true } }
          elseif method == "textDocument/documentSymbol" then
            result = symbols_for(vim.uri_to_bufnr(params.textDocument.uri))
          end
          vim.schedule(function()
            callback(nil, result)
          end)
          return true, id
        end,
        notify = function(method)
          if method == "exit" then
            dispatchers.on_exit(0, 15)
          end
          return true
        end,
        is_closing = function()
          return false
        end,
        terminate = function()
          dispatchers.on_exit(0, 15)
        end,
      }
    end

    ---A module of `n` documented functions, long enough that it parses in several slices.
    local function module(n, marker)
      local lines = {}
      for i = 1, n do
        vim.list_extend(lines, { ("-- doc for f%d"):format(i), ("local function f%d(a)"):format(i) })
        for j = 1, 20 do
          lines[#lines + 1] = ("  local v%d = a * %d"):format(j, j)
        end
        vim.list_extend(lines, { "  return a", "end", "" })
      end
      if marker then
        lines[#lines + 1] = "-- feature marker"
      end
      return lines
    end

    before_each(function()
      tmp, previous_dir = Fixture.enter_tempdir()
      Fixture.feature({ ["big.lua"] = module(300) }, { ["big.lua"] = module(300, true) }, tmp)
      vim.lsp.config("live_server", { cmd = live_server, filetypes = { "lua" }, root_dir = tmp })
      vim.lsp.enable("live_server")
      real_parser = vim.treesitter.get_string_parser
    end)

    after_each(function()
      vim.treesitter.get_string_parser = real_parser
      vim.lsp.enable("live_server", false)
      for _, client in ipairs(vim.lsp.get_clients()) do
        client:stop(true)
      end
      vim.cmd("silent! %bwipeout!")
      vim.fn.chdir(previous_dir)
      vim.fn.delete(tmp, "rf")
    end)

    ---Resolve `big.lua`, calling `on_parse(buf)` on the tick after its text now starts parsing.
    ---@param on_parse fun(buf: integer)
    ---@return { items: changeset.Symbol[]?, comment_lines: changeset.Comments? }?
    local function resolve_while(on_parse)
      local path = tmp .. "/big.lua"
      vim.treesitter.get_string_parser = function(text, ...)
        if text:find("feature marker", 1, true) then
          vim.schedule(function()
            on_parse(vim.fn.bufnr(path))
          end)
        end
        return real_parser(text, ...)
      end
      local file = { path = "big.lua", status = "modified", added = 1, removed = 0, hunks = {}, section = "src" }
      local got
      resolve.start(
        { root = tmp, base = Fixture.git({ "merge-base", "HEAD", "trunk" }, tmp) },
        { file },
        function(_, items, comment_lines)
          got = { items = items, comment_lines = comment_lines }
        end
      )
      vim.wait(15000, function()
        return got ~= nil
      end, 10)
      return got
    end

    it("hands back symbols and comment lines read from the same text", function()
      local got = assert(resolve_while(function(buf)
        vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "local p1", "local p2", "local p3", "local p4", "local p5" })
      end))

      local items = assert(got.items, "no symbols")
      local kinds = assert(got.comment_lines, "no comment lines").new
      local documented = #vim.tbl_filter(function(item)
        return comments.kind(kinds, item.range_lnum - 1) == "comment"
      end, items)
      assert.equal(#items, documented)
    end)
  end)
end)
