---Where a review verb runs from: the sidebar, with its selected row, or a file's window, and the repository it acts on.
local Paths = require("changeset.paths")
local build = require("changeset.build")
local window = require("changeset.window")

local M = {}

---@class changeset.Origin
---@field repository string The tree's when run from the sidebar, whose own buffer names none, else the current buffer's.
---@field sidebar boolean Whether the sidebar has focus.
---@field row changeset.Row? The selected row, only from the sidebar; none on an empty tree.

---Where a review verb runs from, as it stands now.
---@return changeset.Origin
function M.current()
  local tree = build.current()
  local sidebar = window.is_focused()
  return {
    repository = sidebar and tree and tree.root or Paths.root(0),
    sidebar = sidebar,
    row = sidebar and require("changeset.draw").row_at_cursor() or nil,
  }
end

return M
