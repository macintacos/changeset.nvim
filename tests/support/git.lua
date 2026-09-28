---Reachable as `support.git` only because `tests/minimal_init.lua` puts `tests/`
---on `package.path`.
local M = {}

---Run git in `cwd`, asserting it succeeded.
---@param args string[]
---@param cwd string Repository to run in; relative paths in `args` resolve against it.
---@return string
function M.git(args, cwd)
  local out = vim.fn.system(vim.list_extend({ "git", "-C", cwd }, args))
  assert(vim.v.shell_error == 0, out)
  return vim.trim(out)
end

---Initialise a repo on `branch` with one empty commit, and return its SHA.
---@param branch string
---@param cwd string
---@return string
function M.init_repo(branch, cwd)
  M.git({ "init", "-q", "-b", branch }, cwd)
  -- A stray GIT_* var outranks `-C`, so without this the commits and config
  -- below would land in whatever repo it points at.
  local root = vim.fn.resolve(M.git({ "rev-parse", "--show-toplevel" }, cwd))
  assert(root == vim.fn.resolve(cwd), "fixture git repo escaped to " .. root)

  M.git({ "config", "user.email", "test@example.com" }, cwd)
  M.git({ "config", "user.name", "Test" }, cwd)
  M.git({ "config", "commit.gpgsign", "false" }, cwd)
  M.git({ "commit", "-q", "--allow-empty", "-m", "root" }, cwd)
  return M.git({ "rev-parse", "HEAD" }, cwd)
end

---Stage everything and commit it, returning the new HEAD.
---@param message string
---@param cwd string
---@return string
function M.commit(message, cwd)
  M.git({ "add", "-A" }, cwd)
  M.git({ "commit", "-q", "-m", message }, cwd)
  return M.git({ "rev-parse", "HEAD" }, cwd)
end

return M
