---Builds the tree for the current buffer's repository, keeps its diff and symbols fresh, and announces each change
---to its subscribers.

local Git = require("changeset.git")
local Paths = require("changeset.paths")
local cache = require("changeset.cache")
local fork_point = require("changeset.fork_point")
local resolve = require("changeset.resolve")
local tree = require("changeset.tree")

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
---@field default_branch string
---@field pr integer? The branch's open PR, while the tree is measured against its target.
---@field files changeset.File[]
---@field commits integer? Commits on the branch since `base`, once the diff has been read.
---@field collected boolean Whether the diff has been read yet.
---@field symbols table<string, changeset.CachedSymbol[]> Absent key: still reading, or never read (`tree.read_status`).
---@field comments table<string, changeset.Comments> Absent key means none read or parsed for the file.
---@field cancel fun()?
---@field timer uv.uv_timer_t?
---@field request table? The refresh whose answers this session is still listening for.

---What happened to the tree: its `diff` read, one file's `symbols` read, only its `pr` number changed, or its
---diff `failed` to read.
---@alias changeset.TreeEvent "diff"|"symbols"|"pr"|"failed"

---@type changeset.Tree?
local session

---Symbols read for the repo at `root`, carried between builds and to disk.
---@type { root: string, entries: table<string, changeset.CacheEntry> }?
local memo

---@type uv.uv_timer_t?
local save_timer

---@type table<fun(event: changeset.TreeEvent, tree: changeset.Tree), true>
local subscribers = {}

---@param event changeset.TreeEvent
local function announce(event)
  for fn in pairs(subscribers) do
    fn(event, assert(session, "changeset: no open session"))
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
  local buf = vim.fn.bufnr(path)
  return buf ~= -1 and vim.bo[buf].modified
end

---What resolving one file answered.
---@class changeset.build.Answer
---@field items changeset.Symbol[]? nil when no server answered.
---@field comments changeset.Comments?

---File what was read about `path` in the symbol cache, while the cache is still `root`'s.
---@param root string
---@param path string Repo-relative.
---@param answer changeset.build.Answer
---@param stamp string? The file as it stood when its symbols were asked for.
local function file_answer(root, path, answer, stamp)
  if not (memo and memo.root == root and stamp) then
    return
  end
  -- Only an answer that arrived is filed. A server that never attached would
  -- otherwise leave "this file has no symbols" on disk, fresh until the file
  -- next moves; and a stamp taken off the file cannot describe what a server
  -- read out of a buffer holding unwritten edits.
  local items, dirty = answer.items, unwritten(root .. "/" .. path)
  if items and not dirty then
    memo.entries[path] = { stamp = stamp, symbols = cache.project(items), comments = answer.comments }
    save_soon()
  elseif not items then
    -- Not asked again on every refresh — each ask waits out the attach timeout
    -- under a "reading symbols" row — only once the file moves or a server
    -- arrives for it.
    memo.entries[path] = { stamp = stamp, symbols = {}, comments = not dirty and answer.comments or nil, silent = true }
  end
end

---Gather the diff, then let symbols fill in behind it.
function M.refresh()
  if not session then
    return
  end
  if session.cancel then
    session.cancel()
    session.cancel = nil
  end

  -- Identity rather than a counter: an answer from a refresh that this one replaced
  -- has to be dropped, and a session built later starts from a table of its own.
  local request = {}
  session.request = request

  local diff = require("changeset.diff")
  diff.collect(session.base, session.root, function(files, err, commits)
    if not session or session.request ~= request then
      return
    end
    if not files then
      announce("failed")
      return vim.notify("Changeset: " .. (err or "git failed"), vim.log.levels.ERROR)
    end
    session.files = files
    session.commits = commits
    session.collected = true
    local readable = vim.tbl_filter(function(file)
      return tree.read_status(file, session.symbols) ~= "skipped"
    end, files)

    -- Stamped before the request rather than after: a file edited while its
    -- symbols are being read then fails this check next time, instead of
    -- leaving behind an answer for content that has already moved on.
    assert(memo, "changeset: symbol cache not loaded")
    local stamps = {}
    local known, unknown = cache.fresh(memo.entries, readable, function(path)
      assert(session, "changeset: no open session")
      stamps[path] = cache.stamp(session.root .. "/" .. path, session.base)
      return stamps[path]
    end)
    session.symbols = known

    -- Down to what this diff needs: the file caches the branch being read, not
    -- every file whose symbols have ever been asked for.
    local entries = memo.entries
    memo.entries = {}
    session.comments = {}
    for path in pairs(known) do
      memo.entries[path] = entries[path]
      session.comments[path] = entries[path].comments
    end
    announce("diff")

    local root = session.root
    session.cancel = resolve.start({ root = root, base = session.base }, unknown, function(path, items, comment_lines)
      -- Filed even once a newer refresh has replaced this one: the stamp predates
      -- the request, so the answer still describes the file it was read from.
      file_answer(root, path, { items = items, comments = comment_lines }, stamps[path])
      if session and session.request == request then
        -- A server that answers nothing is "resolved with no symbols", which is what
        -- turns every hunk in an unsupported file into an orphan row. Leaving the key
        -- absent would instead read as "still resolving", forever.
        session.symbols[path] = items or {}
        session.comments[path] = comment_lines
        announce("symbols")
      end
    end)
  end)
end

---Let go of the tree, stopping whatever it was still gathering.
local function drop()
  if session then
    if session.cancel then
      session.cancel()
    end
    stop(session.timer)
  end
  session = nil
end

---Build the tree for the current buffer's repository, unless it is already built there.
---
---The buffer's repository, not Neovim's directory: with the two different, a base
---measured in the wrong one leaves every later `git diff` on a bad object.
---@return boolean ready false when the repository has no merge base with its default
---branch, which includes a buffer outside any repository.
function M.build()
  local root = Paths.root(0)
  local branch = Git.lines({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, root)[1] or "HEAD"
  local point = fork_point.get(root, branch)
  if not point then
    return false
  end
  local base = point.base
  if session and session.root == root and session.base == base and session.branch == branch then
    if session.pr ~= point.pr then
      session.pr = point.pr
      announce("pr")
    end
    return true
  end
  drop()

  if not memo or memo.root ~= root then
    memo = { root = root, entries = cache.load(cache.path(root)) }
  end

  session = {
    root = root,
    base = base,
    ref = point.ref,
    branch = branch,
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

-- Fires: gh answering a fork_point lookup, for any repository and branch.
fork_point.subscribe(function(root, branch, point)
  if not (session and session.root == root and session.branch == branch and Paths.root(0) == root) then
    return
  end
  -- An answer of no PR holds a default point no fresher than the tree's; rebuilding on it would ask gh again.
  if not point.pr then
    return
  end
  if session.base == point.base and session.pr == point.pr then
    return
  end
  M.build()
end)

---The tree the last build() made; nil before the first.
---@return changeset.Tree?
function M.current()
  return session
end

---Hear what happens to the tree. Subscribing `fn` again does nothing.
---@param fn fun(event: changeset.TreeEvent, tree: changeset.Tree)
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
    if not (session and memo and client and client:supports_method("textDocument/documentSymbol")) then
      return
    end
    local path = vim.fs.relpath(session.root, vim.fs.normalize(vim.api.nvim_buf_get_name(args.buf)))
    local entry = path and memo.entries[path]
    if path and entry and entry.silent then
      memo.entries[path] = nil
      M.refresh()
    end
  end,
})

local function refresh_soon()
  if not session then
    return
  end
  stop(session.timer)
  session.timer = vim.defer_fn(function()
    if session then
      M.refresh()
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
