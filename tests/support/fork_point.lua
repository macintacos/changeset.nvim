---Fork points measured for specs, awaiting the measure that never blocks.
local fork_point = require("changeset.fork_point")

local M = {}

---The fork point of `branch` at `root`, once `get_async` lands it.
---@param root string
---@param branch string
---@return changeset.ForkPoint?
function M.get(root, branch)
  local done, point = false, nil
  fork_point.get_async(root, branch, function(measured)
    done, point = true, measured
  end)
  assert.is_true(
    vim.wait(10000, function()
      return done
    end, 10),
    "the fork point was never measured"
  )
  return point
end

return M
