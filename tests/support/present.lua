---Asserts a value is present, rejecting only nil, and returns it typed as not nil; `false` needs `assert.is_truthy`.

---@generic T
---@param value T|nil
---@param message? string
---@return T -?
local function present(value, message)
  assert.not_nil(value, message)
  return value
end

return present
