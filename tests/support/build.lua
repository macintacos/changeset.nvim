---Builds the tree as a spec needs it: started, then waited on until it lands.
local M = {}

---Build the tree for the current buffer's repository and wait for the build to land.
---@return boolean? ready As `changeset.build.build` answers it.
function M.build()
  local landed, ready = false, nil
  require("changeset.build").build(function(answer)
    landed, ready = true, answer
  end)
  assert.is_true(
    vim.wait(10000, function()
      return landed
    end, 10),
    "the build never landed"
  )
  return ready
end

return M
