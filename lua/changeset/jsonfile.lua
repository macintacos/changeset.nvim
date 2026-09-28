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

---Replace `file` with `data`, creating the directory it sits in.
---@param file string
---@param data table
---@return boolean written
function M.write(file, data)
  -- `mkdir` raises rather than returning false when the parent cannot be written.
  if not pcall(vim.fn.mkdir, vim.fs.dirname(file), "p") then
    return false
  end
  -- Written beside the file and renamed over it, so an interrupted write leaves the
  -- last good copy standing instead of half of a new one.
  local tmp = file .. ".tmp"
  local fd = io.open(tmp, "w")
  if not fd then
    return false
  end
  if not (fd:write(vim.json.encode(data)) and fd:close() and os.rename(tmp, file)) then
    os.remove(tmp)
    return false
  end
  return true
end

return M
