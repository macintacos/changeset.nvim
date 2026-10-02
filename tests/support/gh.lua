---A fake `gh` on PATH, so no spec asks GitHub about its fixture branch: it prints
---$FAKE_GH_PR after $FAKE_GH_DELAY seconds, and fails as if there were no PR when
---that is empty. Requiring it is what installs it; PATH is never restored, since
---each spec runs in its own nvim. `without` hides it, for a case where gh is not installed.
local bin = vim.fn.tempname()
vim.fn.mkdir(bin, "p")
vim.fn.writefile({
  "#!/bin/sh",
  'sleep "${FAKE_GH_DELAY:-0}"',
  '[ -n "$FAKE_GH_PR" ] || exit 1',
  'printf "%s" "$FAKE_GH_PR"',
}, bin .. "/gh")
vim.fn.setfperm(bin .. "/gh", "rwxr-xr-x")
vim.env.PATH = bin .. ":" .. vim.env.PATH

local M = {}

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
