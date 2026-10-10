---@meta
-- Stubs for the type checker, never run, so their parameters go unused.
--# selene: allow(unused_variable)

-- The globals plenary's busted runner sets for specs.

---@type luassert
assert = nil

---@param desc string
---@param func fun()
function describe(desc, func) end

---@param desc string
---@param func fun()
function it(desc, func) end

---@param desc string
---@param func? fun()
function pending(desc, func) end

---@param fn fun()
function before_each(fn) end

---@param fn fun()
function after_each(fn) end
