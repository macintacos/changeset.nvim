---Records what changeset says through `vim.notify`, in place of showing it.
local M = {}

---@class support.notify.Note
---@field msg string
---@field level integer?

---Replace `vim.notify` with a recorder until `restore` is called.
---@return support.notify.Note[] notes
---@return fun() restore
function M.capture()
  local real, notes = vim.notify, {}
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
  end
  return notes, function()
    vim.notify = real
  end
end

---The messages of `notes`, only those at `level` when one is given.
---@param notes support.notify.Note[]
---@param level integer?
---@return string[]
function M.messages(notes, level)
  return vim
    .iter(notes)
    :filter(function(note)
      return level == nil or note.level == level
    end)
    :map(function(note)
      return note.msg
    end)
    :totable()
end

return M
