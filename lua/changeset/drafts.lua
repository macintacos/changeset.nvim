---Review comment text kept on this machine whenever a save GitHub took didn't close its window; never sent to GitHub.
---
---Every mutation re-reads the file and rewrites only its own PR's list, so two
---Neovims writing drafts don't drop each other's.

local jsonfile = require("changeset.jsonfile")

local M = {}

---@class changeset.Draft : changeset.Spanned
---@field path string
---@field line integer
---@field start_line integer?
---@field head string The PR's head commit the draft was written against.
---@field body string

---@type table<fun(), true>
local subscribers = {}

---Where the record lives. Under `state`, because a draft can't be derived again.
---@return string
function M.path()
  return vim.fs.joinpath(vim.fn.stdpath("state"), "changeset", "drafts.json")
end

---Keyed by the PR's GitHub identity, so a draft follows its PR across branches and clones.
---@param pr changeset.Pr
---@return string
local function key(pr)
  return ("%s/%s/%s#%d"):format(pr.host, pr.owner, pr.name, pr.number)
end

---A hand edit can leave any JSON value where a draft should be.
---@param entry any
---@return boolean
local function valid(entry)
  return type(entry) == "table"
    and type(entry.path) == "string"
    and type(entry.head) == "string"
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

---@param a changeset.Draft
---@param b changeset.Draft
---@return boolean
local function same_key(a, b)
  return a.path == b.path and a.line == b.line and a.start_line == b.start_line and a.head == b.head
end

---@param pr changeset.Pr
---@param data table
---@return changeset.Draft[]
local function valid_drafts(pr, data)
  return vim.tbl_filter(valid, type(data[key(pr)]) == "table" and data[key(pr)] or {})
end

---Writes the PR's list back, removing its key when the list is empty, and tells the subscribers once it lands.
---@param pr changeset.Pr
---@param data table
---@param list changeset.Draft[]
---@return boolean written
local function write(pr, data, list)
  data[key(pr)] = #list > 0 and list or nil
  local written = jsonfile.write(M.path(), data)
  if written then
    for fn in pairs(subscribers) do
      fn()
    end
  end
  return written
end

-- ponytail: old-head drafts are unreachable from a line; list them somewhere if that bites.

---The PR's drafts written against `pr.head`; malformed entries skipped.
---@param pr changeset.Pr
---@return changeset.Draft[]
function M.list(pr)
  return vim.tbl_filter(function(entry)
    return entry.head == pr.head
  end, valid_drafts(pr, jsonfile.read(M.path())))
end

---Replaces the draft at `draft`'s path, range and head; a blank body drops it instead.
---@param pr changeset.Pr
---@param draft changeset.Draft
---@return boolean written false only when the record had to change and the write failed.
function M.keep(pr, draft)
  local data = jsonfile.read(M.path())
  local before = valid_drafts(pr, data)
  local list = vim.tbl_filter(function(entry)
    return not same_key(entry, draft)
  end, before)
  if vim.trim(draft.body) ~= "" then
    table.insert(list, draft)
  elseif #list == #before then
    return true
  end
  return write(pr, data, list)
end

---Removes the draft at `draft`'s path, range and head, writing only if one went.
---@param pr changeset.Pr
---@param draft changeset.Draft
---@return boolean written
function M.drop(pr, draft)
  return M.keep(pr, vim.tbl_extend("force", draft, { body = "" }))
end

---Removes every draft of the PR, at every head.
---@param pr changeset.Pr
---@return boolean written
function M.drop_all(pr)
  local data = jsonfile.read(M.path())
  if data[key(pr)] == nil then
    return true
  end
  return write(pr, data, {})
end

---Calls `fn` after each write. Subscribing again does nothing.
---@param fn fun()
function M.subscribe(fn)
  subscribers[fn] = true
end

return M
