---The git and gh queries that pick the branch changeset diffs against.
local M = {}

---Run a git command and return its stdout lines, or an empty table if it failed.
---@param args string[] Command and arguments, run without a shell; `args[1]` is `git`.
---@param cwd string? Repository to run in. Neovim's own directory when absent, which
---is a different repository whenever the buffer the caller cares about lives elsewhere.
---@return string[]
function M.lines(args, cwd)
  if cwd then
    args = vim.list_extend({ args[1], "-C", cwd }, vim.list_slice(args, 2))
  end
  local out = vim.fn.systemlist(args)
  if vim.v.shell_error ~= 0 then
    return {}
  end
  return out
end

---Resolve the repo's default branch: origin/HEAD's target, else the first of
---main/master/trunk that exists, else "main".
---@param cwd string? Repository to ask; Neovim's own directory when absent.
---@return string branch Short name, with any remote prefix stripped.
function M.default_base(cwd)
  local head = M.lines({ "git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD" }, cwd)[1]
  if head then
    return (head:gsub("^origin/", ""))
  end
  for _, name in ipairs({ "main", "master", "trunk" }) do
    if #M.lines({ "git", "rev-parse", "--verify", "--quiet", name }, cwd) > 0 then
      return name
    end
  end
  return "main"
end

---Resolve the commit where HEAD forked from `branch`.
---@param cwd string? Repository to measure; Neovim's own directory when absent.
---@param branch string? Branch to measure against; the default branch when absent.
---@return string? sha nil outside a repo, when `branch` doesn't exist, or when the two share no ancestor.
---@return string? branch The branch the fork point was taken against.
---@return string? ref The ref whose history holds the fork point, origin's preferred when both do.
function M.merge_base(cwd, branch)
  branch = branch or M.default_base(cwd)
  local refs = vim.tbl_filter(function(ref)
    return #M.lines({ "git", "rev-parse", "--verify", "--quiet", ref }, cwd) > 0
  end, { "origin/" .. branch, branch })
  if #refs == 0 then
    return
  end
  -- Given both, git picks the newer fork point whether local is behind origin or ahead of it.
  local sha = M.lines(vim.list_extend({ "git", "merge-base", "HEAD" }, refs), cwd)[1]
  if not sha then
    return
  end
  for _, ref in ipairs(refs) do
    if M.lines({ "git", "merge-base", sha, ref }, cwd)[1] == sha then
      return sha, branch, ref
    end
  end
end

---Ask gh which branch the current branch's open PR targets.
---@param cwd string? Repository to ask about; Neovim's own directory when absent.
---@param cb fun(target: string?, number: integer?) Both nil without an open PR, or when gh fails or times out.
function M.pr_target(cwd, cb)
  if vim.fn.executable("gh") == 0 then
    return vim.schedule(function()
      cb(nil)
    end)
  end
  vim.system(
    { "gh", "pr", "view", "--json", "baseRefName,number,state" },
    { cwd = cwd, text = true, timeout = 5000 },
    vim.schedule_wrap(function(res)
      local ok, pr = pcall(vim.json.decode, res.stdout or "")
      local open = res.code == 0 and ok and type(pr) == "table" and pr.state == "OPEN"
      cb(open and pr.baseRefName or nil, open and pr.number or nil)
    end)
  )
end

return M
