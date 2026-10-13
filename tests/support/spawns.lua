---Records or holds the processes code starts, to tell what it spawned, whether that blocked Neovim, and what happens
---before it runs.

local M = {}

---Runs `fn`, keeping the argv of every process started through the functions `targets` names, as `{ table, key }`.
---@param targets [table, string][]
---@param fn fun()
---@return string[][]
local function spying(targets, fn)
  local argvs, real = {}, {}
  for i, target in ipairs(targets) do
    local tbl, key = target[1], target[2]
    real[i] = tbl[key]
    tbl[key] = function(argv, ...)
      argvs[#argvs + 1] = argv
      return real[i](argv, ...)
    end
  end
  local ok, err = pcall(fn)
  for i, target in ipairs(targets) do
    target[1][target[2]] = real[i]
  end
  assert.is_true(ok, tostring(err))
  return argvs
end

---Runs `fn`, keeping the argv of every process started through `vim.system`, `vim.fn.jobstart` or `vim.fn.systemlist`.
---A wait belongs inside `fn`: `check-attr` starts from a scheduled callback, after `build()` returns.
---@param fn fun()
---@return string[][]
function M.recording(fn)
  return spying({ { vim, "system" }, { vim.fn, "jobstart" }, { vim.fn, "systemlist" } }, fn)
end

---Runs `fn`, keeping the argv of every process started through `vim.fn.systemlist` or `vim.fn.system`, which block
---Neovim until it exits. A wait belongs inside `fn`.
---@param fn fun()
---@return string[][]
function M.blocking(fn)
  return spying({ { vim.fn, "system" }, { vim.fn, "systemlist" } }, fn)
end

---The calls `holding` keeps unstarted, and what can be done with them.
---@class support.spawns.Held
---@field calls fun()[] Each starts its held call.
---@field stop fun() Stops holding, starting nothing; safe to call twice.
---@field release fun() Stops holding, then starts every held call in the order it was held.

---Holds every call to `Process.run` unstarted from now on, letting through those `pass` accepts.
---@param pass (fun(argv: string[]): boolean)?
---@return support.spawns.Held
function M.holding(pass)
  local Process = require("changeset.process")
  local real = Process.run
  local held ---@type support.spawns.Held
  held = {
    calls = {},
    stop = function()
      Process.run = real
    end,
    release = function()
      held.stop()
      local calls = held.calls
      held.calls = {}
      for _, call in ipairs(calls) do
        call()
      end
    end,
  }
  Process.run = function(argv, opts, on_result)
    if pass and pass(argv) then
      return real(argv, opts, on_result)
    end
    table.insert(held.calls, function()
      real(argv, opts, on_result)
    end)
  end
  return held
end

---Whether `argv` starts `program` with `subcommand`, as `git -C <root> merge-base …` starts git's merge-base.
---@param argv string[]
---@param program string
---@param subcommand string?
---@return boolean
function M.runs(argv, program, subcommand)
  return argv[1] == program and (subcommand == nil or vim.list_contains(argv, subcommand))
end

---Whether `argv` is one of the git subcommands a fork point's measure runs; keep in sync with `fork_point.measure`.
---@param argv string[]
---@return boolean
function M.measuring(argv)
  return argv[2] == "-C"
    and vim.iter({ "merge-base", "reflog", "symbolic-ref" }):any(function(subcommand)
      return M.runs(argv, "git", subcommand)
    end)
end

---Runs `fn`, asserting it measured a fork point and blocked Neovim on no part of that measure.
---@param fn fun()
function M.measures_unblocked(fn)
  local blocked ---@type string[][]
  local spawned = M.recording(function()
    blocked = M.blocking(fn)
  end)
  for _, argv in ipairs(blocked) do
    assert.is_false(M.measuring(argv), table.concat(argv, " "))
  end
  assert.is_true(vim.iter(spawned):any(M.measuring), "nothing was measured")
end

return M
