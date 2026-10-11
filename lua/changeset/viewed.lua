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
function M._apply(data, root, path, digest)
  local out = vim.deepcopy(data)
  out[root] = type(out[root]) == "table" and out[root] or {}
  out[root][path] = digest
  if vim.tbl_isempty(out[root]) then
    out[root] = nil
  end
  return out
end

---Rewrite `file` with `change` applied to its data, never writing over an unreadable record: the marks in it can't
---be derived again.
---@param file string
---@param root string
---@param change fun(data: table): table
---@return changeset.ViewedMarks? marks The root's marks now; nil when the record is unreadable or unwritten.
local function rewrite(file, root, change)
  local data = jsonfile.read_object(file)
  if not data then
    return nil
  end
  local out = change(data)
  if not jsonfile.write(file, vim.tbl_isempty(out) and vim.empty_dict() or out) then
    return nil
  end
  return M.marks(out, root)
end

---Mark `path` viewed at `digest` in `file`, or clear its mark when one holds there.
---@param file string
---@param root string
---@param path string
---@param digest string
---@return changeset.ViewedMarks? marks The root's marks now; nil when the record is unreadable or unwritten.
function M.toggle(file, root, path, digest)
  return rewrite(file, root, function(data)
    local marked = M.holds(M.marks(data, root), path, digest)
    return M._apply(data, root, path, not marked and digest or nil)
  end)
end

---Clear the mark of every one of `files` in `file` when each holds, else mark each viewed at its digest.
---@param file string
---@param root string
---@param files { path: string, digest: string? }[]
---@return changeset.ViewedMarks? marks The root's marks now; nil when the record is unreadable or unwritten.
function M.toggle_all(file, root, files)
  return rewrite(file, root, function(data)
    local marks = M.marks(data, root)
    local all = vim.iter(files):all(function(f)
      return M.holds(marks, f.path, f.digest)
    end)
    for _, f in ipairs(files) do
      data = M._apply(data, root, f.path, not all and f.digest or nil)
    end
    return data
  end)
end

return M
