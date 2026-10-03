---A fake `gh` on PATH, so no spec asks GitHub. Every call sleeps $FAKE_GH_DELAY seconds
---and records its arguments. It then answers with the oldest queued answer, removing it,
---or else prints $FAKE_GH_PR, failing as if there were no PR when that is empty.
---Requiring it is what installs it; PATH is never restored, since each spec runs in its own
---nvim. `without` hides it, for a case where gh is not installed.
local bin = vim.fn.tempname()
local state = vim.fn.tempname()
vim.fn.mkdir(bin, "p")
-- ponytail: concurrent gh calls can race the counters; specs drive one call at a time
vim.fn.writefile({
  "#!/bin/sh",
  'sleep "${FAKE_GH_DELAY:-0}"',
  "state=" .. vim.fn.shellescape(state),
  'mkdir -p "$state"',
  'n=$(( $(cat "$state/count" 2>/dev/null || echo 0) + 1 ))',
  'echo "$n" > "$state/count"',
  'mkdir -p "$state/calls/$n"',
  "i=0",
  'for arg in "$@"; do i=$((i + 1)); printf "%s" "$arg" > "$state/calls/$n/$i"; done',
  'answer=$(ls "$state/answers" 2>/dev/null | sort -n | head -n 1)',
  'if [ -n "$answer" ]; then',
  '  answer="$state/answers/$answer"',
  '  cat "$answer/stdout"',
  '  cat "$answer/stderr" >&2',
  '  code=$(cat "$answer/code")',
  '  rm -r "$answer"',
  '  exit "$code"',
  "fi",
  '[ -n "$FAKE_GH_PR" ] || exit 1',
  'printf "%s" "$FAKE_GH_PR"',
}, bin .. "/gh")
vim.fn.setfperm(bin .. "/gh", "rwxr-xr-x")
vim.env.PATH = bin .. ":" .. vim.env.PATH

local M = {}

local queued = 0

---Queue the answer for the next call that has none: answers go out oldest first.
---@param answer { stdout: string?, stderr: string?, code: integer? }
function M.answer(answer)
  queued = queued + 1
  local dir = ("%s/answers/%d"):format(state, queued)
  vim.fn.mkdir(dir, "p")
  -- writefile turns a newline inside an item into NUL; newlines go between items.
  vim.fn.writefile(vim.split(answer.stdout or "", "\n", { plain = true }), dir .. "/stdout", "b")
  vim.fn.writefile(vim.split(answer.stderr or "", "\n", { plain = true }), dir .. "/stderr", "b")
  vim.fn.writefile({ tostring(answer.code or 0) }, dir .. "/code")
end

local fixtures = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))) .. "/fixtures/github-reviews"

---Queue a recorded GitHub response: `<name>.json` as stdout, plus `<name>.stderr` and
---code 1 when that file exists.
---@param name string
function M.fixture(name)
  local path = ("%s/%s"):format(fixtures, name)
  local failed = vim.fn.filereadable(path .. ".stderr") == 1
  M.answer({
    stdout = vim.fn.readblob(path .. ".json"),
    stderr = failed and vim.fn.readblob(path .. ".stderr") or nil,
    code = failed and 1 or 0,
  })
end

---A `gh pr view --json` body for an open PR on github.com, with `fields` merged over it.
---@param fields table<string, any>
---@return string
function M.pr_view(fields)
  return vim.json.encode(vim.tbl_extend("force", {
    state = "OPEN",
    number = 1,
    url = "https://github.com/owner/repo/pull/1",
    headRefOid = "0123456789abcdef0123456789abcdef01234567",
    author = { login = "owner" },
  }, fields))
end

---Each call's arguments after `gh`, in order, since the last reset.
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

---Forget recorded calls and queued answers.
function M.reset()
  vim.fn.delete(state, "rf")
  queued = 0
end

---Run `fn(...)` with only git on PATH, as if gh were not installed. PATH comes back even when `fn` errors.
---@generic T
---@param fn fun(...): T
---@return T
---@return any ... Any further values `fn` returns.
function M.without(fn, ...)
  local only_git, path = vim.fn.tempname(), vim.env.PATH
  vim.fn.mkdir(only_git, "p")
  vim.uv.fs_symlink(vim.fn.exepath("git"), only_git .. "/git")
  vim.env.PATH = only_git
  local res = vim.F.pack_len(pcall(fn, ...))
  vim.env.PATH = path
  vim.fn.delete(only_git, "rf")
  if not res[1] then
    error(res[2], 0)
  end
  return unpack(res, 2, res.n)
end

return M
