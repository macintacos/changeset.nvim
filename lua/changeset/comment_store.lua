---Review comments kept on this machine, by repository root, in a state record.
---
---Every mutation re-reads the file and rewrites only its own root's list, so two
---Neovims writing comments don't drop each other's.

local jsonfile = require("changeset.jsonfile")

local M = {}

---@class changeset.ReviewComment
---@field path string Repo-relative.
---@field line integer The last line, 1-based.
---@field start_line integer? The first line, only for a range.
---@field body string

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
    and type(entry.line) == "number"
    and entry.line % 1 == 0
    and entry.line >= 1
    and (
      entry.start_line == nil
      or (
        type(entry.start_line) == "number"
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

---Rewrites the root's entries without those `drop` matches, adding `add`, unless nothing would change. An
---unreadable record is never written over, since the comments in it can't be derived again.
---@param root string
---@param drop fun(entry: changeset.ReviewComment): boolean Asked only about valid entries; malformed ones stay.
---@param add changeset.ReviewComment?
---@return boolean written false when the record is unreadable or the write failed.
local function rewrite(root, drop, add)
  local data = jsonfile.read_object(M.path())
  if not data then
    return false
  end
  local before = entries(root, data)
  local list = vim.tbl_filter(function(entry)
    return not (valid(entry) and drop(entry))
  end, before)
  if add then
    table.insert(list, add)
  elseif #list == #before then
    return true
  end
  return write(root, data, list)
end

-- ponytail: comments follow the worktree root, not the branch, and their line numbers are never rebased when
-- the file changes; key by branch and track edits if either bites.

---The comments of the repository at `root`, malformed entries skipped; none from an unreadable record.
---@param root string As `Paths.root` returns it.
---@return changeset.ReviewComment[]
function M.list(root)
  return vim.tbl_filter(valid, entries(root, jsonfile.read_object(M.path()) or {}))
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

---Removes every comment of the repository at `root`, malformed ones included.
---@param root string
---@return boolean written
function M.drop_all(root)
  local data = jsonfile.read_object(M.path())
  if not data then
    return false
  end
  if data[root] == nil then
    return true
  end
  return write(root, data, {})
end

---Calls `fn` after each write. Subscribing again does nothing.
---@param fn fun()
function M.subscribe(fn)
  subscribers[fn] = true
end

return M
