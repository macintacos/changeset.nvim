---@meta
-- Stubs for the type checker, never run, so their parameters go unused.
--# selene: allow(unused_variable)

-- The runtime's `---@operator call:Iter` declares no parameters.
---@class IterMod
---@overload fun(src: table|function, ...: any): Iter

---@class Iter
local Iter = {}

-- The runtime leaves these unannotated, so the return reads as the flag's initial literal.

---@param pred fun(...):boolean
---@return boolean
function Iter:any(pred) end

---@param pred fun(...):boolean
---@return boolean
function Iter:all(pred) end

-- `relative` is empty for a window that isn't floating. The runtime types `title` and `footer` as nil, but a float
-- with one returns it as chunks, each highlight absent when none was set.
---@class vim.api.keyset.win_get_config: vim.api.keyset.win_config_ret
---@field relative ''|'cursor'|'editor'|'laststatus'|'mouse'|'tabline'|'win'
---@field title? [string, string?][]
---@field footer? [string, string?][]

---@param win integer
---@return vim.api.keyset.win_get_config
function vim.api.nvim_win_get_config(win) end
