---A fake `herdr` on PATH, so no spec writes to a real pane. Every call records its
---arguments and answers by command (`agent list`, `pane send-text`, `agent focus`):
---with the oldest answer queued for it, removing it, else the one set for it,
---else an empty success. Requiring it is what installs it; PATH is never restored, since each
---spec runs in its own nvim.
local bin = vim.fn.tempname()
local state = vim.fn.tempname()
vim.fn.mkdir(bin, "p")
-- ponytail: concurrent herdr calls can race the counters; the module makes one call at a time
vim.fn.writefile({
  "#!/bin/sh",
  "state=" .. vim.fn.shellescape(state),
  'mkdir -p "$state"',
  'n=$(( $(cat "$state/count" 2>/dev/null || echo 0) + 1 ))',
  'echo "$n" > "$state/count"',
  'mkdir -p "$state/calls/$n"',
  "i=0",
  'for arg in "$@"; do i=$((i + 1)); printf "%s" "$arg" > "$state/calls/$n/$i"; done',
  'key="$1-$2"',
  'answer=$(ls "$state/queued/$key" 2>/dev/null | sort -n | head -n 1)',
  'if [ -n "$answer" ]; then answer="$state/queued/$key/$answer"; else answer="$state/set/$key"; fi',
  'if [ -d "$answer" ]; then',
  '  cat "$answer/stdout"',
  '  cat "$answer/stderr" >&2',
  '  code=$(cat "$answer/code")',
  '  case "$answer" in "$state/queued/"*) rm -r "$answer";; esac',
  '  exit "$code"',
  "fi",
}, bin .. "/herdr")
vim.fn.setfperm(bin .. "/herdr", "rwxr-xr-x")
vim.env.PATH = bin .. ":" .. vim.env.PATH

local M = {}

---@alias changeset.FakeHerdrAnswer { stdout: string?, stderr: string?, code: integer? }

local queued = 0

---@param dir string
---@param answer changeset.FakeHerdrAnswer
local function write(dir, answer)
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ answer.stdout or "" }, dir .. "/stdout", "b")
  vim.fn.writefile({ answer.stderr or "" }, dir .. "/stderr", "b")
  vim.fn.writefile({ tostring(answer.code or 0) }, dir .. "/code")
end

---@param command string Such as "agent list" or "pane send-text".
---@return string
local function key(command)
  return (command:gsub(" ", "-"))
end

---Answer every `command` call that has nothing queued with `answer`.
---@param command string
---@param answer changeset.FakeHerdrAnswer
function M.set(command, answer)
  write(("%s/set/%s"):format(state, key(command)), answer)
end

---Queue the answer for the next `command` call: answers go out oldest first.
---@param command string
---@param answer changeset.FakeHerdrAnswer
function M.answer(command, answer)
  queued = queued + 1
  write(("%s/queued/%s/%d"):format(state, key(command), queued), answer)
end

---An `agent list` answer holding `agents`.
---@param agents table[]
---@return changeset.FakeHerdrAnswer
function M.agents(agents)
  return { stdout = vim.json.encode({ result = { agents = agents } }) }
end

---A failure with herdr's stderr envelope.
---@param code string Such as "pane_not_found".
---@return changeset.FakeHerdrAnswer
function M.error(code)
  return { stderr = vim.json.encode({ error = { code = code, message = "pane w8:p2 not found" } }), code = 1 }
end

---Each call's arguments after `herdr`, verbatim and in order, since the last reset.
---@return string[][]
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
    table.insert(calls, args)
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
