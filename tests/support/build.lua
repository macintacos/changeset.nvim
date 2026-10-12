---Builds the tree as a spec needs it: started, then waited on until it lands.
local M = {}

---Build the tree for the current buffer's repository and wait for the build to land.
---@return changeset.BuildOutcome
function M.build()
  local landed = false
  local outcome ---@type changeset.BuildOutcome?
  require("changeset.build").build(function(answer)
    landed, outcome = true, answer
  end)
  assert.is_true(
    vim.wait(10000, function()
      return landed
    end, 10),
    "the build never landed"
  )
  return require("support.present")(outcome)
end

return M
