---Records the processes code starts, to tell what it spawned and whether that blocked Neovim.

local M = {}

---Runs `fn`, keeping the argv of every process started through `vim.system` or `vim.fn.systemlist`.
---A wait belongs inside `fn`: `check-attr` starts from a scheduled callback, after `build()` returns.
---@param fn fun()
---@return string[][]
function M.recording(fn)
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
  assert.is_true(ok, tostring(err))
  return argvs
end

---Runs `fn`, keeping the argv of every process started through `vim.fn.systemlist` or `vim.fn.system`, which block
---Neovim until it exits. A wait belongs inside `fn`.
---@param fn fun()
---@return string[][]
function M.blocking(fn)
  local argvs = {}
  local real_system, real_systemlist = vim.fn.system, vim.fn.systemlist
  vim.fn.system = function(argv, ...)
    argvs[#argvs + 1] = argv
    return real_system(argv, ...)
  end
  vim.fn.systemlist = function(argv, ...)
    argvs[#argvs + 1] = argv
    return real_systemlist(argv, ...)
  end
  local ok, err = pcall(fn)
  vim.fn.system, vim.fn.systemlist = real_system, real_systemlist
  assert.is_true(ok, tostring(err))
  return argvs
end

---Whether `argv` starts `program` with `subcommand`, as `git -C <root> merge-base …` starts git's merge-base.
---@param argv string[]
---@param program string
---@param subcommand string?
---@return boolean
function M.runs(argv, program, subcommand)
  return argv[1] == program and (subcommand == nil or vim.list_contains(argv, subcommand))
end

---Whether `argv` is a git command in a repository that only a fork point's measure runs.
---@param argv string[]
---@return boolean
function M.measuring(argv)
  return argv[2] == "-C"
    and vim.iter({ "merge-base", "reflog", "symbolic-ref" }):any(function(subcommand)
      return M.runs(argv, "git", subcommand)
    end)
end

return M
