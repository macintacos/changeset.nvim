---Starts the processes changeset doesn't wait on, through `jobstart`, handing each one's exit code and output back on
---the main loop.
local M = {}

---What `run` hands `argv` and how long it lets it run.
---@class changeset.process.Opts
---@field cwd string?
---@field stdin string? Written to the process, then closed; without it, the process's stdin is null.
---@field timeout integer? Milliseconds.

---What a command `run` started exited with and printed.
---@class changeset.process.Completed
---@field code integer -1 when it could not start; 124 when it ran out of time.
---@field stdout string
---@field stderr string What it printed to stderr; the reason when it could not start.

---A buffered `jobstart` stream's bytes, taking over `data`: its list carries each NUL as "\n" inside an item. CRLF
---reads as LF, so a CRLF file's base text shows and parses without a "\r" on every line.
---@param data string[]
---@return string
local function joined(data)
  for i, item in ipairs(data) do
    if item:find("\n", 1, true) then
      data[i] = item:gsub("\n", "\0")
    end
  end
  local text = table.concat(data, "\n")
  return text:find("\r\n", 1, true) and (text:gsub("\r\n", "\n")) or text
end

---Start `argv` through `jobstart`, whose spawn blocks Neovim a fraction as long as `vim.system`'s, calling
---`on_result` on the main loop. Start it on the main loop: in a fast event `jobstart` can't spawn, and the command
---reads as failed. A failed spawn — a repository removed under a pending refresh, a binary gone since its executable
---check, an argv over the OS's limit — reaches `on_result` as a failed result instead of raising.
---@param argv string[]
---@param opts changeset.process.Opts
---@param on_result fun(result: changeset.process.Completed)
function M.run(argv, opts, on_result)
  local stdout, stderr = {}, {} ---@type string[], string[]
  local timed_out = false
  local ok, job = pcall(vim.fn.jobstart, argv, {
    cwd = opts.cwd,
    stdin = opts.stdin and "pipe" or "null",
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      stdout = data
    end,
    on_stderr = function(_, data)
      stderr = data
    end,
    on_exit = function(_, code)
      on_result({ code = timed_out and 124 or code, stdout = joined(stdout), stderr = joined(stderr) })
    end,
  })
  if not ok or job <= 0 then
    local reason = ok and ("could not start " .. argv[1]) or tostring(job)
    vim.schedule(function()
      on_result({ code = -1, stdout = "", stderr = reason })
    end)
    return
  end
  if opts.stdin then
    vim.fn.chansend(job, opts.stdin)
    vim.fn.chanclose(job, "stdin")
  end
  if opts.timeout then
    vim.defer_fn(function()
      timed_out = vim.fn.jobstop(job) == 1
    end, opts.timeout)
  end
end

return M
