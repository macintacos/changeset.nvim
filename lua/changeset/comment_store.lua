---Review comments kept on this machine, by repository root and the branch each was written on, in a state record.
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
---else a detached HEAD's commit; nil outside a repository. Read off git's own files rather than by running git, since
---every redraw and hover asks.
---@param root string
---@return string?
local function branch_of(root)
  local dir = git_dir(root)
  local head = first_line(vim.fs.joinpath(dir, "HEAD"))
  if not head then
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

---Rewrites the root's entries without those `drop` matches, adding `add` on the branch checked out, unless nothing
---would change. An unreadable record is never written over, since the comments in it can't be derived again.
---@param root string
---@param drop fun(entry: changeset.ReviewComment): boolean Asked only about valid entries the branch shows; the rest stay.
---@param add changeset.ReviewComment?
---@return boolean written false when the record is unreadable or the write failed.
local function rewrite(root, drop, add)
  local data = jsonfile.read_object(M.path())
  if not data then
    return false
  end
  local branch = branch_of(root)
  local before = entries(root, data)
  local list = vim.tbl_filter(function(entry)
    return not (valid(entry) and on(entry, branch) and drop(entry))
  end, before)
  if add then
    table.insert(list, vim.tbl_extend("force", add, { branch = branch }))
  elseif #list == #before then
    return true
  end
  return write(root, data, list)
end

---The comments of the repository at `root` that the branch checked out shows, malformed entries skipped; none from
---an unreadable record.
---@param root string As `Paths.root` returns it.
---@return changeset.ReviewComment[]
function M.list(root)
  local branch = branch_of(root)
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

---Removes, in one write, each stored comment equal to one of `comments`, body included, so one edited since stays.
---@param root string
---@param comments changeset.ReviewComment[]
---@return boolean written
function M.drop_each(root, comments)
  return rewrite(root, function(entry)
    return vim.iter(comments):any(function(comment)
      return same_range(entry, comment) and entry.body == comment.body
    end)
  end)
end

---@class changeset.ReviewCommentMove
---@field from changeset.ReviewComment As listed.
---@field to changeset.ReviewComment `from` on the lines it moves to.

---Puts each stored comment equal to a move's `from` on its `to`'s lines, in one write. Comments that end up on one
---range merge into the first, their bodies a blank line apart, a draft when any was, so the store keeps one a range.
---@param root string
---@param moves changeset.ReviewCommentMove[]
---@return boolean written
function M.move(root, moves)
  local data = jsonfile.read_object(M.path())
  if not data then
    return false
  end
  local branch = branch_of(root)
  local list, on_range = {}, {}
  for _, entry in ipairs(entries(root, data)) do
    if valid(entry) and on(entry, branch) then
      local move = vim.iter(moves):find(function(each)
        return same_range(entry, each.from) and entry.body == each.from.body and entry.draft == each.from.draft
      end)
      if move then
        entry = vim.deepcopy(entry)
        entry.line, entry.start_line = move.to.line, move.to.start_line
      end
      local key = ("%s:%s:%s"):format(entry.path, entry.start_line, entry.line)
      local into = on_range[key]
      if into then
        into.body, into.draft = into.body .. "\n\n" .. entry.body, into.draft or entry.draft
      else
        on_range[key], list[#list + 1] = entry, entry
      end
    else
      list[#list + 1] = entry
    end
  end
  return write(root, data, list)
end

---Removes every comment of the repository at `root` that the branch checked out shows.
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
