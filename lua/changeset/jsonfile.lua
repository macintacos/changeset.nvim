---The small JSON records changeset keeps under `stdpath`.
---
---A file that cannot be read counts as absent, because every one of these is a
---convenience that must not stop the thing that reads it from starting.
local M = {}

---@param file string
---@return table data Empty when the file is missing, unreadable, or not a JSON object.
function M.read(file)
  local fd = io.open(file, "r")
  if not fd then
    return {}
  end
  local content = fd:read("*a")
  fd:close()
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then
    return {}
  end
  return data
end

---`file` as a JSON object, `null` read as absent, for a record that must not be written over when unreadable.
---@param file string
---@return table? data Empty when the file is missing; nil when it exists but can't be opened or isn't a JSON object.
function M.read_object(file)
  local fd = io.open(file, "r")
  if not fd then
    return not vim.uv.fs_stat(file) and {} or nil
  end
  local content = fd:read("*a")
  fd:close()
  local ok, data = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
  if ok and type(data) == "table" and not (vim.islist(data) and #data > 0) then
    return data
  end
end

---Replace `file` with `data`, creating the directory it sits in.
---@param file string
---@param data table|string A string is written as it is: JSON already encoded.
---@return boolean written
function M.write(file, data)
  -- `mkdir` raises rather than returning false when the parent cannot be written.
  if not pcall(vim.fn.mkdir, vim.fs.dirname(file), "p") then
    return false
  end
  -- Written beside the file and renamed over it, so an interrupted write leaves the
  -- last good copy standing instead of half of a new one.
  -- Named per process, so two Neovims writing at once never interleave in one temp file.
  local tmp = ("%s.%d.tmp"):format(file, vim.uv.os_getpid())
  local fd = io.open(tmp, "w")
  if not fd then
    return false
  end
  local wrote = fd:write(type(data) == "string" and data or vim.json.encode(data))
  if not (fd:close() and wrote and os.rename(tmp, file)) then
    os.remove(tmp)
    return false
  end
  return true
end

return M
