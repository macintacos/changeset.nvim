---Which files a reviewer marked viewed, each against the exact diff it was viewed at, remembered across sessions.

local jsonfile = require("changeset.jsonfile")

local M = {}

---@alias changeset.ViewedMarks table<string, string> The digest of the diff each path was marked on.

---Where the record lives, shaped `{ [root] = { [path] = digest } }`.
---@return string
function M.path()
  return vim.fs.joinpath(vim.fn.stdpath("state") --[[@as string]], "changeset", "viewed.json")
end

---Read the record from `file`.
---@param file string
---@return table data Empty when the file is missing or corrupt.
function M.load(file)
  return jsonfile.read(file)
end

---The marks of `root` in `data`, malformed entries skipped.
---@param data table
---@param root string
---@return changeset.ViewedMarks
function M.marks(data, root)
  local marks = {}
  local entries = data[root]
  if type(entries) ~= "table" then
    return marks
  end
  for path, digest in pairs(entries) do
    if type(path) == "string" and type(digest) == "string" then
      marks[path] = digest
    end
  end
  return marks
end

---Whether `path` is marked viewed at `digest`.
---@param marks changeset.ViewedMarks
---@param path string
---@param digest string?
---@return boolean
function M.holds(marks, path, digest)
  return digest ~= nil and marks[path] == digest
end

---`data` with `path` of `root` marked at `digest`, or cleared when it is nil.
---@param data table Left unmodified.
---@param root string
---@param path string
---@param digest string?
---@return table
function M.apply(data, root, path, digest)
  local out = vim.deepcopy(data)
  out[root] = type(out[root]) == "table" and out[root] or {}
  out[root][path] = digest
  if vim.tbl_isempty(out[root]) then
    out[root] = nil
  end
  return out
end

---Mark `path` viewed at `digest` in `file`, or clear its mark when one holds there.
---@param file string
---@param root string
---@param path string
---@param digest string
---@return changeset.ViewedMarks? marks The root's marks now; nil when the record is unreadable or unwritten.
function M.toggle(file, root, path, digest)
  -- Never written over when unreadable: the marks in it can't be derived again.
  local data = jsonfile.read_object(file)
  if not data then
    return nil
  end
  local marked = M.holds(M.marks(data, root), path, digest)
  local out = M.apply(data, root, path, not marked and digest or nil)
  if not jsonfile.write(file, vim.tbl_isempty(out) and vim.empty_dict() or out) then
    return nil
  end
  return M.marks(out, root)
end

return M
