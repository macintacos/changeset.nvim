---The git and gh queries that pick the branch changeset diffs against, HEAD read off git's own files, and the process
---runner they and herdr share.
local M = {}

---`vim.system`, calling `on_exit` on the main loop. A failed spawn — a repository removed under a pending
---refresh, a binary gone since its executable check, an argv over the OS's limit — reaches `on_exit` as a failed
---result instead of raising.
---@param argv string[]
---@param opts vim.SystemOpts
---@param on_exit fun(result: vim.SystemCompleted)
function M.system(argv, opts, on_exit)
  local ok, err = pcall(vim.system, argv, opts, vim.schedule_wrap(on_exit))
  if not ok then
    local result = { code = -1, signal = 0, stdout = "", stderr = tostring(err) }
    vim.schedule(function()
      on_exit(result)
    end)
  end
end

---The first line of the file at `path`; nil when it can't be read, as a directory can't.
---@param path string
---@return string?
function M.first_line(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local line = fd:read("*l")
  fd:close()
  return line
end

---The git directory of the repository at `root`: its `.git`, or where a worktree's `.git` file points.
---@param root string
---@return string
function M.git_dir(root)
  local dot_git = vim.fs.joinpath(root, ".git")
  local pointer = (M.first_line(dot_git) or ""):match("^gitdir: (.+)")
  if not pointer then
    return dot_git
  end
  return vim.fn.isabsolutepath(pointer) == 1 and pointer or vim.fs.joinpath(root, pointer)
end

---HEAD's branch and commit at `root`, as `git rev-parse HEAD --abbrev-ref HEAD` answers them: "HEAD" for a detached
---HEAD, a stopped rebase's included. Read off git's own files, since every refresh asks; git runs only where they can't
---say: a reftable repository, an unreadable HEAD, a branch with no loose ref (unborn, or packed).
---@param root string
---@return string? branch nil outside a repository and on an unborn branch.
---@return string? commit
function M.head(root)
  local dir = M.git_dir(root)
  local line = M.first_line(vim.fs.joinpath(dir, "HEAD")) or ""
  if line:match("^%x+$") then
    return "HEAD", line
  end
  local name = line:match("^ref: refs/heads/(.+)")
  -- A reftable repository's HEAD always names `.invalid`.
  if name and name ~= ".invalid" then
    -- A worktree's branches live in the repository it was added from.
    local common = M.first_line(vim.fs.joinpath(dir, "commondir"))
    if common then
      dir = vim.fn.isabsolutepath(common) == 1 and common or vim.fs.joinpath(dir, common)
    end
    local commit = M.first_line(vim.fs.joinpath(dir, "refs", "heads", name))
    if commit and commit:match("^%x+$") then
      return name, commit
    end
  end
  local out = M.lines({ "git", "rev-parse", "HEAD", "--abbrev-ref", "HEAD" }, root)
  return out[2], out[1]
end

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
---main/master/trunk that exists locally or on origin, else "main".
---@param cwd string? Repository to ask; Neovim's own directory when absent.
---@return string branch Short name, with any remote prefix stripped.
function M.default_base(cwd)
  local head = M.lines({ "git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD" }, cwd)[1]
  if head then
    return (head:gsub("^origin/", ""))
  end
  for _, name in ipairs({ "main", "master", "trunk" }) do
    local found = vim.iter({ name, "origin/" .. name }):any(function(ref)
      return #M.lines({ "git", "rev-parse", "--verify", "--quiet", ref }, cwd) > 0
    end)
    if found then
      return name
    end
  end
  return "main"
end

---What HEAD moved from when it moved to `branch` at `commit`, as this worktree's HEAD reflog records it.
---@param cwd string?
---@param branch string
---@param commit string The commit `branch` was created at, which tells its move from an earlier branch's of that name.
---@return string? from A branch name, or a commit when HEAD was detached.
local function moved_from(cwd, branch, commit)
  local moved = "^" .. vim.pesc(commit) .. " checkout: moving from (%S+) to " .. vim.pesc(branch) .. "$"
  return vim
    .iter(M.lines({ "git", "reflog", "show", "--format=%H %gs", "HEAD" }, cwd))
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
  local log = M.lines({ "git", "reflog", "show", "--format=%H %gs", "refs/heads/" .. branch }, cwd)
  local commit, source = (log[#log] or ""):match("^(%x+) branch: Created from (.+)$")
  if source == "HEAD" then
    source = moved_from(cwd, branch, commit)
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

---Whether `ancestor` is in `commit`'s history, `commit` itself included.
---@param cwd string Repository to ask.
---@param ancestor string
---@param commit string
---@return boolean
function M.is_ancestor(cwd, ancestor, commit)
  vim.fn.system({ "git", "-C", cwd, "merge-base", "--is-ancestor", ancestor, commit })
  return vim.v.shell_error == 0
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

---Ask gh which branch the current branch's open PR targets.
---@param cwd string? Repository to ask about; Neovim's own directory when absent.
---@param cb fun(target: string?, number: integer?) Both nil without an open PR, or when gh fails or times out.
function M.pr_target(cwd, cb)
  if vim.fn.executable("gh") == 0 then
    return vim.schedule(function()
      cb(nil)
    end)
  end
  M.system(
    { "gh", "pr", "view", "--json", "baseRefName,number,state" },
    { cwd = cwd, text = true, timeout = 5000 },
    function(res)
      local ok, pr = pcall(vim.json.decode, res.stdout or "")
      local open = res.code == 0 and ok and type(pr) == "table" and pr.state == "OPEN"
      cb(open and pr.baseRefName or nil, open and pr.number or nil)
    end
  )
end

return M
