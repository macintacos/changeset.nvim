---View state that must survive a rebuild: where the cursor was, and which rows
---are folded. Both are keyed by row identity rather than by line, because a
---refresh reorders lines whenever the file set changes.

---@class changetree.State
---@field collapsed table<string, true> Rows whose children are hidden.
---@field chains table<string, true> Compressed chains the user opened out.

local M = {}

---@return changetree.State
function M.new()
  return { collapsed = {}, chains = {} }
end

---@param st changetree.State
---@param id string
---@return boolean
function M.is_collapsed(st, id)
  return st.collapsed[id] == true
end

---@param st changetree.State
---@param id string
---@param collapsed boolean
function M.set_collapsed(st, id, collapsed)
  st.collapsed[id] = collapsed or nil
end

---@param st changetree.State
---@param ids string[]
function M.collapse_all(st, ids)
  for _, id in ipairs(ids) do
    st.collapsed[id] = true
  end
end

---@param st changetree.State
function M.expand_all(st)
  st.collapsed = {}
end

---Whether a compressed chain is being shown at full nesting.
---
---A separate axis from `collapsed`: compression hides a chain's *intermediate*
---rows, folding hides a row's children, and `l` on a compressed row means the
---first while `h` on a file means the second.
---@param st changetree.State
---@param id string
---@return boolean
function M.is_chain_open(st, id)
  return st.chains[id] == true
end

---@param st changetree.State
---@param id string
---@param open boolean
function M.set_chain_open(st, id, open)
  st.chains[id] = open or nil
end

---The line to put the cursor on after a rebuild.
---@param ids string[] Row ids, in display order.
---@param wanted string? Id the cursor sat on before the rebuild.
---@param fallback integer Line to keep when that id is gone.
---@return integer lnum 1-based, always within `ids`.
function M._reanchor(ids, wanted, fallback)
  for lnum, id in ipairs(ids) do
    if id == wanted then
      return lnum
    end
  end
  return math.max(1, math.min(fallback, #ids))
end

return M
