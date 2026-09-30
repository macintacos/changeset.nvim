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
  describe("_resolvable", function()
    it("keeps files in the order they are displayed, so the tree fills top-down", function()
      local files = {
        { path = "api.ts", status = "modified" },
        { path = "auth.ts", status = "added" },
      }

      assert.same({ "api.ts", "auth.ts" }, resolve._resolvable(files))
    end)

    it("skips a deleted file, which has no content left to read symbols from", function()
      local files = {
        { path = "gone.ts", status = "deleted" },
        { path = "auth.ts", status = "modified" },
      }

      assert.same({ "auth.ts" }, resolve._resolvable(files))
    end)
  end)

  describe("_walk", function()
    ---@return string[]
    local function ten_files()
      local queue = {}
      for i = 1, 10 do
        queue[i] = i .. ".ts"
      end
      return queue
    end

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
        { { path = path, status = "added", added = 1, removed = 0, hunks = {} } },
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
      local file = { path = "README.md", status = "modified", added = 1, removed = 0, hunks = {} }

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
end)
