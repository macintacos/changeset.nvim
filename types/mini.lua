---@meta

---@generic T
---@param module T
---@return T?
local function set_up(module) end

-- mini sets these in its `setup()`, so they are nil until then. Field names are not checked through `set_up`, narrowed
-- or not, so read a mini API off `require` after the nil guard.
MiniPick = set_up(require("mini.pick"))
MiniIcons = set_up(require("mini.icons"))
