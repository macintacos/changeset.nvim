---Builds the tree for the current buffer's repository, keeps it fresh, and announces each change.

local Git = require("changeset.git")
local Paths = require("changeset.paths")
local buffers = require("changeset.buffers")
local cache = require("changeset.cache")
local fork_point = require("changeset.fork_point")
local resolve = require("changeset.resolve")
local Rows = require("changeset.rows")

-- `:wall` writes every buffer, and regaining focus reloads every file changed
-- meanwhile. One rebuild per burst is enough, and a rebuild mid-keypress is what
-- the identity re-anchoring exists to survive.
local REFRESH_DEBOUNCE_MS = 250

-- One write per burst of answers rather than one per file.
local SAVE_DEBOUNCE_MS = 1000

local M = {}

---The tree as the pipeline keeps it. Only this module writes these fields.
---@class changeset.Tree
---@field root string
---@field base string
---@field ref string Ref the fork point was measured against, e.g. "origin/trunk".
---@field branch string
---@field head string? HEAD's commit when the tree was built.
---@field default_branch string
---@field pr integer? The branch's open PR, while the tree is measured against its target.
---@field files changeset.File[]
---@field commits integer? Commits on the branch since `base`, once the diff has been read.
---@field collected boolean Whether the diff has been read yet.
---@field symbols table<string, changeset.CachedSymbol[]> Absent key: still reading, or never read (`Rows.read_status`).
---@field comments table<string, changeset.Comments> Absent key means none read or parsed for the file.

---What happened to the tree: its `diff` read, one file's `symbols` read, only its `pr` number changed, or its
---diff `failed` to read.
---@alias changeset.TreeEvent "diff"|"symbols"|"pr"|"failed"

---@type changeset.Tree?
local tree

---What the current tree's pipeline is still doing; replaced with the tree.
---@class changeset.build.Work
---@field cancel fun()? Stops the symbol reads still running.
---@field timer uv.uv_timer_t? The debounced refresh waiting to run.
---@field request table? The refresh whose answers are still wanted.

---@type changeset.build.Work
local work = {}

---Symbols read for the repo at `root`, carried between builds and to disk.
---@type { root: string, entries: table<string, changeset.CacheEntry> }?
local memo

---@type uv.uv_timer_t?
local save_timer

---@type table<fun(event: changeset.TreeEvent), true>
local subscribers = {}

---@param event changeset.TreeEvent
local function announce(event)
  for fn in pairs(subscribers) do
    fn(event)
  end
end

---Stop a deferred callback for good. `vim.defer_fn` closes its handle from inside the
---callback, so a timer replaced before it fires leaves one open.
---@param timer uv.uv_timer_t?
local function stop(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

local function save_soon()
  stop(save_timer)
  save_timer = vim.defer_fn(function()
    if memo then
      cache.save(cache.path(memo.root), memo.entries)
    end
  end, SAVE_DEBOUNCE_MS)
end

---Whether the file at `path` holds edits the file on disk does not.
---@param path string Absolute.
---@return boolean
local function unwritten(path)
  -- Buffer names are already absolute and simplified, so the raw name nearly always finds it without normalising each.
  local buf = vim.iter(vim.api.nvim_list_bufs()):find(function(b)
    return vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == path
  end) or buffers.loaded(path)
  return buf ~= nil and vim.bo[buf].modified
end

---What reading one file's symbols answered.
---@class changeset.build.Answer
---@field items changeset.Symbol[]? nil when no server answered.
---@field comments changeset.Comments?

---File what was read about `path` in the symbol cache, while the cache is still `root`'s.
---@param root string
---@param path string Repo-relative.
---@param answer changeset.build.Answer
---@param stamp string? The file as it stood when its symbols were asked for.
---@return changeset.CachedSymbol[]? filed The symbols filed for `path`, which a later refresh's cache hands back as the
---same table; nil when none were filed.
local function file_answer(root, path, answer, stamp)
  if not (memo and memo.root == root and stamp) then
    return nil
  end
  -- Only an answer that arrived is filed. A server that never attached would
  -- otherwise leave "this file has no symbols" on disk, fresh until the file
  -- next moves; and a stamp taken off the file cannot describe what a server
  -- read out of a buffer holding unwritten edits.
  local items, dirty = answer.items, unwritten(root .. "/" .. path)
  if items and not dirty then
    memo.entries[path] = { stamp = stamp, symbols = cache.project(items), comments = answer.comments }
    -- Encoded now, a little per answer, rather than the whole cache at once on the next save.
    cache.encode(memo.entries[path])
    save_soon()
    return memo.entries[path].symbols
  elseif not items then
    -- An older walk's late silence must not bury an answer about the same file state.
    local entry = memo.entries[path]
    if entry and not entry.silent and entry.stamp == stamp then
      return nil
    end
    -- Not asked again on every refresh — each ask waits out the attach timeout
    -- under a "reading symbols" row — only once the file moves or a server
    -- arrives for it.
    memo.entries[path] = { stamp = stamp, symbols = {}, comments = not dirty and answer.comments or nil, silent = true }
    return memo.entries[path].symbols
  end
  return nil
end

local HUNK_FIELDS = { "lnum", "count", "added", "removed", "old_lnum" }
local FILE_FIELDS = { "path", "oldpath", "status", "section", "added", "removed" }

---Whether `a` and `b` hold the same diff of the same file.
---@param a changeset.File
---@param b changeset.File
---@return boolean
local function same_file(a, b)
  local function same(x, y, fields)
    return vim.iter(fields):all(function(field)
      return x[field] == y[field]
    end)
  end
  if not (same(a, b, FILE_FIELDS) and #a.hunks == #b.hunks) then
    return false
  end
  for i, hunk in ipairs(a.hunks) do
    if not same(hunk, b.hunks[i], HUNK_FIELDS) then
      return false
    end
  end
  return true
end

---`files`, each one `previous` already holds swapped for that one: rows built for a file are kept by its identity.
---@param previous changeset.File[]
---@param files changeset.File[]
---@return changeset.File[]
local function keep_identity(previous, files)
  local by_path = {}
  for _, file in ipairs(previous) do
    by_path[file.path] = file
  end
  return vim.tbl_map(function(file)
    local old = by_path[file.path]
    return old and same_file(old, file) and old or file
  end, files)
end

---Gather the diff, then let symbols fill in behind it.
function M.refresh()
  if not tree then
    return
  end
  if work.cancel then
    work.cancel()
    work.cancel = nil
  end

  -- Identity rather than a counter: an answer from a refresh that this one replaced
  -- has to be dropped, and a tree built later starts from a table of its own.
  local request = {}
  work.request = request

  local diff = require("changeset.diff")
  diff.collect(tree.base, tree.root, function(files, err, commits)
    if not tree or work.request ~= request then
      return
    end
    if not files then
      announce("failed")
      return vim.notify("Changeset: " .. (err or "git failed"), vim.log.levels.ERROR)
    end
    tree.files = keep_identity(tree.files, files)
    tree.commits = commits
    tree.collected = true
    local readable = vim.tbl_filter(function(file)
      return not Rows.skips(file)
    end, tree.files)

    -- Stamped before the request rather than after: a file edited while its
    -- symbols are being read then fails this check next time, instead of
    -- leaving behind an answer for content that has already moved on.
    assert(memo, "changeset: symbol cache not loaded")
    local stamps = {}
    local known, unknown = cache.fresh(memo.entries, readable, function(path)
      assert(tree, "changeset: no tree built yet")
      stamps[path] = cache.stamp(tree.root .. "/" .. path, tree.base)
      return stamps[path]
    end)
    tree.symbols = known

    -- Down to what this diff needs: the file caches the branch being read, not
    -- every file whose symbols have ever been asked for.
    local entries = memo.entries
    memo.entries = {}
    tree.comments = {}
    for path in pairs(known) do
      memo.entries[path] = entries[path]
      tree.comments[path] = entries[path].comments
    end
    announce("diff")

    local root = tree.root
    work.cancel = resolve.start({ root = root, base = tree.base }, unknown, function(path, items, comment_lines)
      -- Filed even once a newer refresh has replaced this one: the stamp predates
      -- the request, so the answer still describes the file it was read from.
      local filed = file_answer(root, path, { items = items, comments = comment_lines }, stamps[path])
      if tree and work.request == request then
        -- A server that answers nothing is "read, with no symbols", which is what
        -- turns every hunk in an unsupported file into an orphan row. Leaving the key
        -- absent would instead read as "still reading", forever.
        tree.symbols[path] = filed or items or {}
        tree.comments[path] = comment_lines
        announce("symbols")
      end
    end)
  end)
end

---Let go of the tree, stopping whatever it was still gathering.
local function drop()
  if work.cancel then
    work.cancel()
  end
  stop(work.timer)
  work = {}
  tree = nil
end

local place

---Build the tree for the repository at `root`, unless it is already built there.
---@param root string
---@return boolean ready false when the repository has no merge base with its default
---branch, which includes a `root` outside any repository.
local function build_at(root)
  local branch, commit = Git.head(root)
  branch = branch or "HEAD"
  return place(root, branch, commit, fork_point.get(root, branch))
end

---Keep the tree when `point` is the one it was built on, else build one there.
---@param root string
---@param branch string
---@param commit string?
---@param point changeset.ForkPoint?
---@return boolean ready false without a fork point.
place = function(root, branch, commit, point)
  if not point then
    return false
  end
  local base = point.base
  if tree and tree.root == root and tree.base == base and tree.branch == branch then
    tree.head = commit
    if tree.pr ~= point.pr then
      tree.pr = point.pr
      announce("pr")
    end
    return true
  end
  drop()

  if not memo or memo.root ~= root then
    if memo and save_timer and not save_timer:is_closing() then
      stop(save_timer)
      cache.save(cache.path(memo.root), memo.entries)
    end
    memo = { root = root, entries = cache.load(cache.path(root)) }
  end

  tree = {
    root = root,
    base = base,
    ref = point.ref,
    branch = branch,
    head = commit,
    default_branch = point.default_branch,
    pr = point.pr,
    files = {},
    collected = false,
    symbols = {},
    comments = {},
  }
  M.refresh()
  return true
end

---Build the tree for the current buffer's repository, unless it is already built there.
---
---The buffer's repository, not Neovim's directory: with the two different, a base
---measured in the wrong one leaves every later `git diff` on a bad object.
---@return boolean ready false when the repository has no merge base with its default
---branch, which includes a buffer outside any repository.
function M.build()
  return build_at(Paths.root(0))
end

---The tree, while it is for the current buffer's repository and HEAD is still on its branch.
---@return changeset.Tree?
function M.kept()
  if not (tree and tree.root == Paths.root(0)) then
    return nil
  end
  if (Git.head(tree.root) or "HEAD") == tree.branch then
    return tree
  end
end

---@type table? The re-measure in flight; a newer one replaces it.
local remeasuring

---Measure the tree's fork point again without blocking, then do what `build()` would with it: keep the tree on the
---same one, else rebuild it. Dropped once the tree is replaced or a newer re-measure starts.
---@param on_no_base fun()? Called when the re-measure finds no fork point, keeping the tree.
function M.remeasure(on_no_base)
  local kept = tree
  if not kept then
    return
  end
  local request = {}
  remeasuring = request
  fork_point.get_async(kept.root, kept.branch, function(point)
    if remeasuring ~= request or tree ~= kept then
      return
    end
    remeasuring = nil
    local branch, commit = Git.head(kept.root)
    local ready
    if (branch or "HEAD") ~= kept.branch then
      ready = build_at(kept.root)
    else
      ready = place(kept.root, kept.branch, commit, point)
    end
    if not ready and on_no_base then
      on_no_base()
    end
  end)
end

---Rebuild the tree when its repository's HEAD has moved or landed on another branch, else refresh it.
function M.update()
  if not tree then
    return
  end
  local branch, commit = Git.head(tree.root)
  -- A detached HEAD (a stopped rebase, a bisect) is not another branch.
  if not branch or branch == "HEAD" or (branch == tree.branch and commit == tree.head) then
    return M.refresh()
  end
  if branch == tree.branch then
    -- A moved HEAD can come with a PR retargeted, merged or closed.
    fork_point.recheck(tree.root, branch)
    M.remeasure()
    return M.refresh()
  end
  local kept = tree
  if not build_at(tree.root) or tree == kept then
    M.refresh()
  end
end

-- Fires: gh answering a fork_point lookup, for any repository and branch.
fork_point.subscribe(function(root, branch, point)
  if not (tree and tree.root == root and tree.branch == branch) then
    return
  end
  -- An answer that leaves no PR holds a point no fresher than the tree's, unless the tree's PR is gone.
  if not point.pr and not tree.pr then
    return
  end
  if tree.base == point.base and tree.pr == point.pr then
    return
  end
  build_at(root)
end)

---The tree the last build() made; nil before the first.
---@return changeset.Tree?
function M.current()
  return tree
end

---Hear what happens to the tree. Subscribing `fn` again does nothing.
---@param fn fun(event: changeset.TreeEvent)
function M.subscribe(fn)
  subscribers[fn] = true
end

-- Fires: a language server attaching to any buffer. A file no server answered for
-- is not asked about again until it changes, so one that attaches late — started
-- slowly, or installed since — would otherwise never be heard from.
vim.api.nvim_create_autocmd("LspAttach", {
  group = vim.api.nvim_create_augroup("changeset.servers", { clear = true }),
  desc = "changeset: ask again about a file once a server that lists symbols reaches it",
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    if not (tree and memo and client and client:supports_method("textDocument/documentSymbol")) then
      return
    end
    local path = Paths.relative(tree.root, vim.api.nvim_buf_get_name(args.buf))
    local entry = path and memo.entries[path]
    if path and entry and entry.silent then
      memo.entries[path] = nil
      M.refresh()
    end
  end,
})

local function refresh_soon()
  if not tree then
    return
  end
  stop(work.timer)
  work.timer = vim.defer_fn(function()
    -- A removed worktree would otherwise raise on every write and focus change; `R` still reports it.
    if tree and vim.uv.fs_stat(tree.root) then
      M.update()
    end
  end, REFRESH_DEBOUNCE_MS)
end

local watch = vim.api.nvim_create_augroup("changeset.watch", { clear = true })

-- Fires: a write, a buffer reloaded after its file changed outside Neovim, and Neovim
-- regaining focus — the moments the files git diffs from disk can have moved.
-- Nothing else does: the diff reads the disk, so unwritten edits never move it.
vim.api.nvim_create_autocmd({ "BufWritePost", "FileChangedShellPost", "FocusGained" }, {
  group = watch,
  desc = "changeset: rebuild the tree after the working tree changes",
  callback = refresh_soon,
})

-- Fires: gitsigns seeing HEAD move, a checkout or rebase made anywhere, which it
-- publishes without a buffer. The per-buffer ones fire on every attach and every
-- hunk change while typing, and the symbol walk's own loads would restart it.
vim.api.nvim_create_autocmd("User", {
  pattern = "GitSignsUpdate",
  group = watch,
  desc = "changeset: rebuild the tree after the branch changes",
  callback = function(args)
    if not (args.data and args.data.buffer) then
      refresh_soon()
    end
  end,
})

return M
