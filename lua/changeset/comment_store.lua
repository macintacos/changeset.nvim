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

---@param root string
---@param data table
---@return changeset.ReviewComment[]
local function valid_comments(root, data)
  return vim.tbl_filter(valid, type(data[root]) == "table" and data[root] or {})
end

---Writes the root's list back, removing its key when the list is empty, and tells the subscribers once it lands.
---@param root string
---@param data table
---@param list changeset.ReviewComment[]
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

-- ponytail: comments follow the worktree root, not the branch, and their line numbers are never rebased when
-- the file changes; key by branch and track edits if either bites.

---The comments of the repository at `root`, malformed entries skipped.
---@param root string As `Paths.root` returns it.
---@return changeset.ReviewComment[]
function M.list(root)
  return valid_comments(root, jsonfile.read(M.path()))
end

---Replaces the comment at `comment`'s path and range; a blank body drops it instead.
---@param root string
---@param comment changeset.ReviewComment
---@return boolean written false only when the record had to change and the write failed.
function M.keep(root, comment)
  local data = jsonfile.read(M.path())
  local before = valid_comments(root, data)
  local list = vim.tbl_filter(function(entry)
    return not same_range(entry, comment)
  end, before)
  if vim.trim(comment.body) ~= "" then
    table.insert(list, comment)
  elseif #list == #before then
    return true
  end
  return write(root, data, list)
end

---Removes the comment at `comment`'s path and range, writing only if one went.
---@param root string
---@param comment changeset.ReviewComment
---@return boolean written
function M.drop(root, comment)
  return M.keep(root, vim.tbl_extend("force", comment, { body = "" }))
end

---Removes every comment of the repository at `root`.
---@param root string
---@return boolean written
function M.drop_all(root)
  local data = jsonfile.read(M.path())
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
