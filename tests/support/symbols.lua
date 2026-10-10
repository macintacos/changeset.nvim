---An in-memory symbol source over `resolve.start`: each ask waits until the spec answers it.
local resolve = require("changeset.resolve")

local M = {}

---@class support.symbols.Ask
---@field paths string[] The files asked about.
---@field answer fun(path: string, items: changeset.Symbol[]?, comments: changeset.Comments?) Answers this ask only.

---@class support.symbols.Source
---@field asks support.symbols.Ask[]
---@field answer fun(path: string, items: changeset.Symbol[]?, comments: changeset.Comments?) Answers the latest ask.
---@field restore fun() Puts `resolve.start` back.

---Replace `resolve.start` with a source that holds every ask for the spec to answer.
---@return support.symbols.Source
function M.install()
  local real_start = resolve.start
  local asks = {}
  resolve.start = function(_, files, on_file)
    asks[#asks + 1] = {
      paths = vim.tbl_map(function(file)
        return file.path
      end, files),
      answer = on_file,
    }
    return function() end
  end
  return {
    asks = asks,
    ---Answers the latest ask.
    answer = function(path, items, comments)
      asks[#asks].answer(path, items, comments)
    end,
    restore = function()
      resolve.start = real_start
    end,
  }
end

return M
