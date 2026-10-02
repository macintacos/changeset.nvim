---The sidebar's own state for the current tree: its rows, View, Position and preferences file.

local build = require("changeset.build")
local position = require("changeset.position")
local prefs = require("changeset.prefs")
local view = require("changeset.view")

local M = {}

---@class changeset.SidebarState
---@field tree changeset.Tree The tree this state was made for.
---@field file string Preferences file.
---@field rows changeset.Row[]
---@field view changeset.View What the sidebar shows of the tree.
---@field position changeset.Position Where the user stands in this tree.

---@type changeset.SidebarState?
local state

---The sidebar's state for the current tree, made afresh once a build has replaced the tree: only folds and
---opened chains carry over, kept per repository by `view.for_root`. Read it again after a wait or a later callback.
---@return changeset.SidebarState?
function M.current()
  local tree = build.current()
  if not tree then
    return nil
  end
  if not (state and state.tree == tree) then
    local file = prefs.path()
    state = {
      tree = tree,
      file = file,
      rows = {},
      view = view.for_root(tree.root, prefs.resolve(prefs.load(file), tree.root, tree.branch)),
      position = position.new(),
    }
  end
  return state
end

return M
