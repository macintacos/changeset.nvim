local Process = require("changeset.process")
local present = require("support.present")

describe("changeset.process", function()
  describe("run", function()
    ---Run `argv` through `Process.run`, waiting for its result.
    ---@param argv string[]
    ---@param opts changeset.process.Opts
    ---@return changeset.process.Completed
    local function run(argv, opts)
      local got ---@type changeset.process.Completed?
      Process.run(argv, opts, function(result)
        got = result
      end)
      assert.is_true(vim.wait(5000, function()
        return got ~= nil
      end, 10))
      return present(got)
    end

    local real_system = vim.system

    -- A failing `run` raises before a spec could restore its stub.
    after_each(function()
      vim.system = real_system
    end)

    it("starts its process without vim.system, whose spawn blocks Neovim longer", function()
      local calls = 0
      vim.system = function(...)
        calls = calls + 1
        return real_system(...)
      end

      assert.equal(0, run({ "git", "--version" }, {}).code)
      assert.equal(0, calls)
    end)

    it("hands a failed spawn to its callback on the main loop as a failed result", function()
      local real = vim.fn.jobstart
      vim.fn.jobstart = function()
        error("E2BIG")
      end
      local got ---@type changeset.process.Completed?
      local fast
      Process.run({ "git", "status" }, {}, function(result)
        got, fast = result, vim.in_fast_event()
      end)
      vim.fn.jobstart = real
      assert.is_nil(got)
      vim.wait(1000, function()
        return got ~= nil
      end)
      local result = present(got)
      assert.equal(-1, result.code)
      assert.matches("E2BIG", present(result.stderr))
      assert.is_false(fast)
    end)

    it("calls back on the main loop with the process's result", function()
      local got ---@type changeset.process.Completed?
      local fast
      Process.run({ "git", "--version" }, {}, function(result)
        got, fast = result, vim.in_fast_event()
      end)
      vim.wait(5000, function()
        return got ~= nil
      end)
      local result = present(got)
      assert.equal(0, result.code)
      assert.matches("^git version", present(result.stdout))
      assert.is_false(fast)
    end)

    it("keeps NUL bytes in stdout", function()
      assert.equal("a\0b\n", run({ "printf", "a\\0b\\n" }, {}).stdout)
    end)

    it("reads CRLF output as LF", function()
      assert.equal("a\nb\n", run({ "printf", "a\\r\\nb\\r\\n" }, {}).stdout)
    end)

    it("writes stdin to the process with its NUL bytes", function()
      assert.equal("x\0y\nz", run({ "cat" }, { stdin = "x\0y\nz" }).stdout)
    end)

    it("captures a failing command's stderr", function()
      local result = run({ "sh", "-c", "echo oops >&2; exit 3" }, {})
      assert.equal(3, result.code)
      assert.equal("oops\n", result.stderr)
    end)

    it("stops a command that outlives its timeout and reports code 124", function()
      local start = vim.uv.now()
      assert.equal(124, run({ "sleep", "5" }, { timeout = 50 }).code)
      assert.is_true(vim.uv.now() - start < 2000)
    end)

    it("reports the exit code of a command that exits as its timeout fires", function()
      local real_jobstart, real_defer = vim.fn.jobstart, vim.defer_fn
      local timeout ---@type fun()?
      vim.defer_fn = function(fn)
        timeout = fn
        return present(vim.uv.new_timer())
      end
      vim.fn.jobstart = function(argv, opts)
        local on_exit = present(opts).on_exit
        present(opts).on_exit = function(...)
          present(timeout)()
          return on_exit(...)
        end
        return real_jobstart(argv, opts)
      end
      local ok, result = pcall(run, { "true" }, { timeout = 5000 })
      vim.fn.jobstart, vim.defer_fn = real_jobstart, real_defer
      assert.is_true(ok, tostring(result))
      assert.equal(0, result.code)
    end)
  end)
end)
