---Runs git and gh: the branch changeset diffs against, its open PR, and every other gh call.
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
---@param branch string Branch to measure against.
---@return string? sha nil outside a repo, when `branch` doesn't exist, or when the two share no ancestor.
---@return string? ref The ref whose history holds the fork point, origin's preferred when both do.
function M.merge_base(cwd, branch)
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
      return sha, ref
    end
  end
end

---Run gh without a shell; hand `cb` its decoded JSON stdout, or why it failed.
---@param args string[] Arguments after `gh`.
---@param opts { cwd: string?, timeout: integer }
---@param cb fun(err: string?, out: any) Called on the main loop.
function M.gh(args, opts, cb)
  local function fail(err)
    vim.schedule(function()
      cb(err)
    end)
  end
  if vim.fn.executable("gh") == 0 then
    return fail("`gh` not found")
  end
  local argv = vim.list_extend({ "gh" }, args)
  local ok, err = pcall(
    vim.system,
    argv,
    { cwd = opts.cwd, text = true, timeout = opts.timeout },
    vim.schedule_wrap(function(res)
      local decoded, out = pcall(vim.json.decode, res.stdout or "", { luanil = { object = true, array = true } })
      out = decoded and out or nil
      local errors = type(out) == "table" and out.errors
      if res.code ~= 0 or errors then
        local stderr = vim.trim(res.stderr or "")
        cb(
          errors and errors[1] and errors[1].message
            or (stderr ~= "" and stderr)
            or ("gh exited with code %d"):format(res.code)
        )
      elseif not decoded then
        cb("gh printed output that isn't JSON")
      else
        cb(nil, out)
      end
    end)
  )
  if not ok then
    fail(tostring(err))
  end
end

---@class changeset.Pr
---@field target string Branch the PR merges into.
---@field number integer
---@field owner string Owner of the repository the PR was opened against, a fork's upstream included.
---@field name string That repository's name.
---@field head string Head commit.
---@field author string Login of whoever opened it.

---Ask gh for the open PR of the branch checked out at `cwd`.
---@param cwd string? Repository to ask about; Neovim's own directory when absent.
---@param cb fun(err: string?, pr: changeset.Pr?)
function M.pr(cwd, cb)
  -- ponytail: github.com only; pass --hostname from the PR url's host when GHE matters
  M.gh(
    { "pr", "view", "--json", "author,baseRefName,headRefOid,number,state,url" },
    { cwd = cwd, timeout = 5000 },
    function(err, pr)
      if err then
        return cb(err)
      end
      if pr.state ~= "OPEN" then
        return cb(("PR #%s is %s"):format(pr.number, pr.state))
      end
      local owner, name
      if type(pr.url) == "string" then
        owner, name = pr.url:match("^https?://[^/]+/([^/]+)/([^/]+)/pull/%d+$")
      end
      if not owner then
        return cb(("PR #%s has no repository url: %s"):format(pr.number, tostring(pr.url)))
      end
      cb(nil, {
        target = pr.baseRefName,
        number = pr.number,
        owner = owner,
        name = name,
        head = pr.headRefOid,
        author = pr.author and pr.author.login,
      })
    end
  )
end

return M
