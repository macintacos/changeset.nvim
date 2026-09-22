local resolve = require("plugins.changeset.resolve")

---A step that parks each call so the spec decides when it answers.
---@return fun(path: string, done: fun(items: MiniPickers.Symbol[]?)) run
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
    it("opens a fifth lane only once one of the first four closes", function()
      local run, pending = deferred()
      local queue = {}
      for i = 1, 10 do
        queue[i] = i .. ".ts"
      end

      resolve._walk(queue, run, function() end)
      assert.equal(4, #pending)

      pending[1].done({})
      assert.equal(5, #pending)
    end)

    it("reports nothing once cancelled", function()
      local run, pending = deferred()
      local seen = {}

      local cancel = resolve._walk({ "api.ts", "auth.ts" }, run, function(path)
        seen[#seen + 1] = path
      end)
      cancel()
      pending[1].done({})

      assert.same({}, seen)
    end)

    it("keeps walking past a file its step had no symbols for", function()
      local run, pending = deferred()
      local seen = {}

      resolve._walk({ "api.ts", "auth.ts", "db.ts", "ui.ts", "log.ts" }, run, function(path, items)
        seen[#seen + 1] = { path = path, items = items }
      end)
      pending[1].done(nil)

      assert.equal(1, #seen)
      assert.equal("api.ts", seen[1].path)
      assert.is_nil(seen[1].items)
      assert.equal(5, #pending)
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
end)
