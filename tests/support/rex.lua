---A fake `rex` on PATH, so no spec writes to a real pane. Every call records its
---arguments and stdin and answers by command (`do`, `api`, `focus`): with the oldest
---answer queued for it, removing it, else the one set for it, else an empty success.
---Requiring it is what installs it; PATH is never restored, since each spec runs in its own nvim.
local bin = vim.fn.tempname()
local state = vim.fn.tempname()
vim.fn.mkdir(bin, "p")
-- ponytail: concurrent rex calls can race the counters; the module makes one call at a time
vim.fn.writefile({
  "#!/bin/sh",
  "state=" .. vim.fn.shellescape(state),
  'mkdir -p "$state"',
  'n=$(( $(cat "$state/count" 2>/dev/null || echo 0) + 1 ))',
  'echo "$n" > "$state/count"',
  'mkdir -p "$state/calls/$n"',
  "i=0",
  'for arg in "$@"; do i=$((i + 1)); printf "%s" "$arg" > "$state/calls/$n/$i"; done',
  'cat > "$state/stdin.$n"',
  'key="$1"',
  'answer=$(ls "$state/queued/$key" 2>/dev/null | sort -n | head -n 1)',
  'if [ -n "$answer" ]; then answer="$state/queued/$key/$answer"; else answer="$state/set/$key"; fi',
  'if [ -d "$answer" ]; then',
  '  cat "$answer/stdout"',
  '  cat "$answer/stderr" >&2',
  '  code=$(cat "$answer/code")',
  '  case "$answer" in "$state/queued/"*) rm -r "$answer";; esac',
  '  exit "$code"',
  "fi",
}, bin .. "/rex")
vim.fn.setfperm(bin .. "/rex", "rwxr-xr-x")
vim.env.PATH = bin .. ":" .. vim.env.PATH

local M = {}

---@alias changeset.FakeRexAnswer { stdout: string?, stderr: string?, code: integer? }

local queued = 0

---@param dir string
---@param answer changeset.FakeRexAnswer
local function write(dir, answer)
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ answer.stdout or "" }, dir .. "/stdout", "b")
  vim.fn.writefile({ answer.stderr or "" }, dir .. "/stderr", "b")
  vim.fn.writefile({ tostring(answer.code or 0) }, dir .. "/code")
end

---Answer every `command` call that has nothing queued with `answer`.
---@param command string The first argument, such as "do" or "api".
---@param answer changeset.FakeRexAnswer
function M.set(command, answer)
  write(("%s/set/%s"):format(state, command), answer)
end

---Queue the answer for the next `command` call: answers go out oldest first.
---@param command string
---@param answer changeset.FakeRexAnswer
function M.answer(command, answer)
  queued = queued + 1
  write(("%s/queued/%s/%d"):format(state, command, queued), answer)
end

---A `do` answer listing `panes` as the module's listing script returns them.
---@param panes table[]
---@return changeset.FakeRexAnswer
function M.panes(panes)
  return { stdout = vim.json.encode({ panes = panes }) }
end

---A failure, exiting with `code` as rex does: 3 when a target is not found.
---@param code integer
---@return changeset.FakeRexAnswer
function M.error(code)
  return { stderr = 'Error: block target "block:gone" not found', code = code }
end

---Each call's arguments after `rex`, verbatim and in order, with what it read on stdin, since the last reset.
---@return { args: string[], stdin: string }[]
function M.calls()
  local calls = {}
  local n = 1
  while vim.fn.isdirectory(("%s/calls/%d"):format(state, n)) == 1 do
    local args, i = {}, 1
    local path = ("%s/calls/%d/%d"):format(state, n, i)
    while vim.fn.filereadable(path) == 1 do
      table.insert(args, vim.fn.readblob(path))
      i = i + 1
      path = ("%s/calls/%d/%d"):format(state, n, i)
    end
    table.insert(calls, { args = args, stdin = vim.fn.readblob(("%s/stdin.%d"):format(state, n)) })
    n = n + 1
  end
  return calls
end

---Forget recorded calls and every answer.
function M.reset()
  vim.fn.delete(state, "rf")
  queued = 0
end

return M
