---Review comments kept on this machine, by repository root and the branch each was written on, in a state record,
---beside the ones each branch submitted last.
---
---Every mutation re-reads the file and rewrites only its own root's list, so two
---Neovims writing comments don't drop each other's.

local jsonfile = require("changeset.jsonfile")

local M = {}

---@class changeset.ReviewComment
---@field path string Repo-relative.
---@field line integer? The last line, 1-based; nil for a comment on the whole file.
---@field start_line integer? The first line, only for a range.
---@field body string
---@field draft true? Kept but not saved, so submit and yank leave it out.

---@class changeset.StoredReviewComment : changeset.ReviewComment
---@field branch string? The branch it was written on, or a detached HEAD's commit; nil before branches were recorded.

---@type table<fun(), true>
local subscribers = {}

-- The record's key for the comments `take` keeps, by root then branch: no root, an absolute path, is named this.
local TAKEN = "submitted"

---Whether `a` sorts ahead of `b`: by path, then first line, then last line, a whole file's comment first.
---@param a changeset.ReviewComment
---@param b changeset.ReviewComment
---@return boolean
function M.before(a, b)
  if a.path ~= b.path then
    return a.path < b.path
  end
  local a_first, b_first = a.start_line or a.line or 0, b.start_line or b.line or 0
  if a_first ~= b_first then
    return a_first < b_first
  end
  return (a.line or 0) < (b.line or 0)
end

---Where the record lives. Under `state`, because a comment can't be derived again.
---@return string
function M.path()
  return vim.fs.joinpath(vim.fn.stdpath("state"), "changeset", "comments.json")
end

---A hand edit can leave any JSON value where a comment should be.
---@param entry any
---@return boolean
local function valid(entry)
  return type(entry) == "table"
    and type(entry.path) == "string"
    and type(entry.body) == "string"
    and (entry.line == nil or (type(entry.line) == "number" and entry.line % 1 == 0 and entry.line >= 1))
    and (entry.draft == nil or entry.draft == true)
    and (entry.branch == nil or type(entry.branch) == "string")
    and (
      entry.start_line == nil
      or (
        entry.line ~= nil
        and type(entry.start_line) == "number"
        and entry.start_line % 1 == 0
        and entry.start_line >= 1
        and entry.start_line < entry.line
      )
    )
end

---@param a changeset.ReviewComment
---@param b changeset.ReviewComment
---@return boolean
local function same_range(a, b)
  return a.path == b.path and a.line == b.line and a.start_line == b.start_line
end

---The first line of the file at `path`; nil when it can't be read, as a directory can't.
---@param path string
---@return string?
local function first_line(path)
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
local function git_dir(root)
  local dot_git = vim.fs.joinpath(root, ".git")
  local pointer = (first_line(dot_git) or ""):match("^gitdir: (.+)")
  if not pointer then
    return dot_git
  end
  return vim.fn.isabsolutepath(pointer) == 1 and pointer or vim.fs.joinpath(root, pointer)
end

---What the repository at `root` files its comments under: the branch checked out, the one a stopped rebase rewrites,
---else a detached HEAD's commit; nil outside a repository and in a reftable one. Read off git's own files rather than
---by running git, since every redraw and hover asks.
---@param root string
---@return string?
function M.branch(root)
  local dir = git_dir(root)
  local head = first_line(vim.fs.joinpath(dir, "HEAD"))
  -- A reftable repository's HEAD file always names this; only git can say what is checked out.
  if not head or head == "ref: refs/heads/.invalid" then
    return nil
  end
  local name = head:match("^ref: refs/heads/(.+)")
  for _, rebase in ipairs({ "rebase-merge", "rebase-apply" }) do
    name = name or (first_line(vim.fs.joinpath(dir, rebase, "head-name")) or ""):match("^refs/heads/(.+)")
  end
  return name or head
end

---Whether `entry` shows on `branch`: written there, or before branches were recorded.
---@param entry changeset.StoredReviewComment
---@param branch string?
---@return boolean
local function on(entry, branch)
  return entry.branch == nil or entry.branch == branch
end

---The root's entries as stored, malformed ones included.
---@param root string
---@param data table
---@return any[]
local function entries(root, data)
  return type(data[root]) == "table" and data[root] or {}
end

---`data[key]` when it is a table: a hand edit can leave any JSON value there.
---@param data table
---@param key string
---@return table
local function field(data, key)
  return type(data[key]) == "table" and data[key] or {}
end

---The comments `take` took last from `branch` of `root`, as stored.
---@param data table
---@param root string
---@param branch string?
---@return any[]
local function taken(data, root, branch)
  return field(field(field(data, TAKEN), root), branch or "")
end

---Keeps `list` as the comments taken last from `branch` of `root`, removing every key it empties.
---@param data table
---@param root string
---@param branch string?
---@param list changeset.ReviewComment[]
local function set_taken(data, root, branch, list)
  local roots = field(data, TAKEN)
  local branches = field(roots, root)
  branches[branch or ""] = #list > 0 and list or nil
  roots[root] = next(branches) and branches or nil
  data[TAKEN] = next(roots) and roots or nil
end

---Writes the root's list back, removing its key when the list is empty, and tells the subscribers once it lands.
---@param root string
---@param data table
---@param list any[]
---@return boolean written
local function write(root, data, list)
  data[root] = #list > 0 and list or nil
  local written = jsonfile.write(M.path(), data)
  if written then
    for fn in pairs(subscribers) do
      fn()
    end
  end
  return written
end

---Rewrites the root's entries without those `drop` matches, adding `add` on the branch checked out and keeping `took`
---as the comments that branch took last, unless nothing would change. An unreadable record is never written over,
---since the comments in it can't be derived again.
---@param root string
---@param drop fun(entry: changeset.ReviewComment): boolean Asked only about valid entries the branch shows; the rest stay.
---@param add changeset.ReviewComment?
---@param took changeset.ReviewComment[]? Replaces the comments taken last; empty forgets them, nil leaves them.
---@return boolean written false when the record is unreadable or the write failed.
local function rewrite(root, drop, add, took)
  local data = jsonfile.read_object(M.path())
  if not data then
    return false
  end
  local branch = M.branch(root)
  local before = entries(root, data)
  local list = vim.tbl_filter(function(entry)
    return not (valid(entry) and on(entry, branch) and drop(entry))
  end, before)
  if took then
    set_taken(data, root, branch, took)
  end
  if add then
    table.insert(list, vim.tbl_extend("force", add, { branch = branch }))
  elseif #list == #before and not took then
    return true
  end
  return write(root, data, list)
end

---The comments of the repository at `root` that the branch checked out shows, malformed entries skipped; none from
---an unreadable record.
---@param root string As `Paths.root` returns it.
---@return changeset.ReviewComment[]
function M.list(root)
  local branch = M.branch(root)
  return vim
    .iter(entries(root, jsonfile.read_object(M.path()) or {}))
    :filter(function(entry)
      return valid(entry) and on(entry, branch)
    end)
    :map(function(entry)
      return {
        path = entry.path,
        line = entry.line,
        start_line = entry.start_line,
        body = entry.body,
        draft = entry.draft,
      }
    end)
    :totable()
end

---Replaces the comment at `comment`'s path and range; a blank body drops it instead.
---@param root string
---@param comment changeset.ReviewComment
---@return boolean written false when the record had to change and couldn't be.
function M.keep(root, comment)
  return rewrite(root, function(entry)
    return same_range(entry, comment)
  end, vim.trim(comment.body) ~= "" and comment or nil)
end

---Removes the comment at `comment`'s path and range, writing only if one went.
---@param root string
---@param comment changeset.ReviewComment
---@return boolean written
function M.drop(root, comment)
  return M.keep(root, vim.tbl_extend("force", comment, { body = "" }))
end

---Takes out, in one write, each stored comment equal to one of `comments`, body included, so one edited since stays;
---and keeps `comments` for `restore`, in place of the ones the branch took before.
---@param root string
---@param comments changeset.ReviewComment[]
---@return boolean written
function M.take(root, comments)
  return rewrite(root, function(entry)
    return vim.iter(comments):any(function(comment)
      return same_range(entry, comment) and entry.body == comment.body
    end)
  end, nil, comments)
end

---Brings back, in one write, the comments the branch checked out took last, as saved ones. One whose range holds a
---comment now stays taken, as the store keeps one a range; the rest are forgotten.
---@param root string
---@return integer? restored nil when the record is unreadable or the write failed.
---@return integer kept Still taken, for a restore once their ranges are free.
function M.restore(root)
  local data = jsonfile.read_object(M.path())
  if not data then
    return nil, 0
  end
  local branch = M.branch(root)
  local took = taken(data, root, branch)
  if #took == 0 then
    return 0, 0
  end
  local list = entries(root, data)
  local back, kept = {}, {}
  for _, comment in ipairs(vim.tbl_filter(valid, took)) do
    local held = vim.iter(list):any(function(entry)
      return valid(entry) and on(entry, branch) and same_range(entry, comment)
    end)
    table.insert(held and kept or back, comment)
  end
  for _, comment in ipairs(back) do
    list[#list + 1] = {
      path = comment.path,
      line = comment.line,
      start_line = comment.start_line,
      body = comment.body,
      branch = branch,
    }
  end
  set_taken(data, root, branch, kept)
  if not write(root, data, list) then
    return nil, 0
  end
  return #back, #kept
end

---@class changeset.ReviewCommentMove
---@field from changeset.ReviewComment As listed.
---@field to changeset.ReviewComment `from` on the lines it moves to.

---@class changeset.ReviewCommentMerge
---@field comment changeset.StoredReviewComment The comment the others merged into, as it ends up.
---@field count integer How many comments it holds now.

---A copy of `entry`, on the lines of the move made from it, filed under `branch` when it has none, as `keep` files it.
---@param entry changeset.StoredReviewComment
---@param moves changeset.ReviewCommentMove[]
---@param branch string?
---@return changeset.StoredReviewComment
local function moved(entry, moves, branch)
  local copy = vim.deepcopy(entry)
  local move = vim.iter(moves):find(function(each)
    return same_range(entry, each.from) and entry.body == each.from.body and entry.draft == each.from.draft
  end)
  if move then
    copy.line, copy.start_line, copy.branch = move.to.line, move.to.start_line, entry.branch or branch
  end
  return copy
end

---`stored` with each the branch shows on the lines of the move made from it. Comments that end up on one range merge
---into the first listed, their bodies a blank line apart, a draft when any was, so the store keeps one a range.
---@param stored any[] As stored, malformed ones included, which stay as they are.
---@param moves changeset.ReviewCommentMove[]
---@param branch string?
---@return any[] entries
---@return changeset.ReviewCommentMerge[] merged
function M._relocate(stored, moves, branch)
  local list, on_range, merged = {}, {}, {}
  for _, entry in ipairs(stored) do
    if valid(entry) and on(entry, branch) then
      entry = moved(entry, moves, branch)
      local key = ("%s:%s:%s"):format(entry.path, entry.start_line, entry.line)
      local into = on_range[key]
      if into then
        local comment = into.comment
        comment.body, comment.draft = comment.body .. "\n\n" .. entry.body, comment.draft or entry.draft
        comment.branch = comment.branch or branch
        into.count = into.count + 1
        if into.count == 2 then
          merged[#merged + 1] = into
        end
      else
        on_range[key], list[#list + 1] = { comment = entry, count = 1 }, entry
      end
    else
      list[#list + 1] = entry
    end
  end
  return list, merged
end

---Puts each stored comment equal to a move's `from` on its `to`'s lines, in one write, merging those that end up on
---one range.
---@param root string
---@param moves changeset.ReviewCommentMove[]
---@return boolean written
---@return changeset.ReviewCommentMerge[] merged
function M.move(root, moves)
  local data = jsonfile.read_object(M.path())
  if not data then
    return false, {}
  end
  local list, merged = M._relocate(entries(root, data), moves, M.branch(root))
  return write(root, data, list), merged
end

---Removes every comment of the repository at `root` that the branch checked out shows, leaving those it took last.
---@param root string
---@return boolean written
function M.drop_all(root)
  return rewrite(root, function()
    return true
  end)
end

---Calls `fn` after each write. Subscribing again does nothing.
---@param fn fun()
function M.subscribe(fn)
  subscribers[fn] = true
end

return M
