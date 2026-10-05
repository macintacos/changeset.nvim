---The git and gh queries changeset makes: the branch it diffs against, that branch's open PR, whether a file on disk matches a commit, and the gh runner every GitHub call goes through.
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

---Whether the file at `path` on disk is the one commit `commit` holds; nil when the clone lacks `commit`.
---@param root string The repository's top level; `path` is relative to it.
---@param commit string
---@param path string Repo-relative.
---@return boolean?
function M.matches_commit(root, commit, path)
  -- Without `^{commit}`, `--verify --quiet` echoes a missing full SHA back and succeeds.
  if #M.lines({ "git", "rev-parse", "--verify", "--quiet", commit .. "^{commit}" }, root) == 0 then
    return nil
  end
  local at_commit = M.lines({ "git", "rev-parse", "--verify", "--quiet", commit .. ":" .. path }, root)[1]
  return at_commit ~= nil and at_commit == M.lines({ "git", "hash-object", "--", path }, root)[1]
end

---What HEAD moved from the first time it moved to `branch`, as this worktree's HEAD reflog records it.
---@param cwd string?
---@param branch string
---@return string? from A branch name, or a commit when HEAD was detached.
local function moved_from(cwd, branch)
  local moved = "^checkout: moving from (%S+) to " .. vim.pesc(branch) .. "$"
  return vim
    .iter(M.lines({ "git", "reflog", "show", "--format=%gs", "HEAD" }, cwd))
    :rev()
    :map(function(entry)
      return entry:match(moved)
    end)
    :next()
end

---The branch `branch` was created from, as the first entry of its reflog records it, named without its remote.
---`git switch -c` and `git checkout -b` record only HEAD, so for them it is the branch HEAD moved from to reach
---`branch`, provided that move was made in this worktree.
---@param cwd string? Repository to ask; Neovim's own directory when absent.
---@param branch string
---@return string? parent nil when `branch` was created from a commit, a detached HEAD, another worktree's HEAD or
---its own remote counterpart, when that branch is gone, and when the reflogs no longer hold its creation.
function M.parent(cwd, branch)
  local log = M.lines({ "git", "reflog", "show", "--format=%gs", "refs/heads/" .. branch }, cwd)
  local source = (log[#log] or ""):match("^branch: Created from (.+)$")
  if source == "HEAD" then
    source = moved_from(cwd, branch)
  end
  if not source then
    return
  end
  local ref = M.lines({ "git", "rev-parse", "--symbolic-full-name", source }, cwd)[1] or ""
  local name = ref:match("^refs/heads/(.+)$") or ref:match("^refs/remotes/[^/]+/(.+)$")
  if name ~= branch then
    return name
  end
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

---Run gh without a shell; hand `cb` its decoded JSON stdout, or why it failed. A non-zero exit,
---output that isn't JSON, or a GraphQL `errors` body even on exit 0 is a failure.
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
  local started, err = pcall(
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
  if not started then
    fail(tostring(err))
  end
end

---@class changeset.Pr
---@field target string Branch the PR merges into.
---@field number integer
---@field owner string Owner of the repository the PR was opened against, a fork's upstream included.
---@field name string That repository's name.
---@field host string Host the PR lives on, from its url.
---@field head string SHA of the PR's head commit when gh answered (`headRefOid`).
---@field author string? Login of whoever opened it.

---Ask gh for the open PR of the branch checked out at `cwd`.
---@param cwd string? Repository to ask about; Neovim's own directory when absent.
---@param cb fun(err: string?, pr: changeset.Pr?) `err` when the branch has no open PR (none, closed or merged), when the url names no repository, or when gh fails or times out.
function M.pr(cwd, cb)
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
      local host, owner, name
      if type(pr.url) == "string" then
        host, owner, name = pr.url:match("^https?://([^/]+)/([^/]+)/([^/]+)/pull/%d+$")
      end
      if not owner then
        return cb(("PR #%s has no repository url: %s"):format(pr.number, tostring(pr.url)))
      end
      cb(nil, {
        target = pr.baseRefName,
        number = pr.number,
        owner = owner,
        name = name,
        host = host,
        head = pr.headRefOid,
        author = pr.author and pr.author.login,
      })
    end
  )
end

return M
