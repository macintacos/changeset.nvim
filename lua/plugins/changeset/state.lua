---View state that must survive a rebuild: where the cursor was, and which rows
---are folded. Both are keyed by row identity rather than by line, because a
---refresh reorders lines whenever the file set changes.
---
---The `_`-prefixed functions are pure decisions alongside it: where the cursor
---lands after a rebuild, and where `h` goes from a row.

---@class changeset.State
---@field collapsed table<string, true> Rows whose children are hidden.
---@field chains table<string, true> Compressed chains the user opened out.

local M = {}

---A fresh view state: nothing folded, no chain opened out.
---@return changeset.State
function M.new()
  return { collapsed = {}, chains = {} }
end

---Whether the row's children are hidden.
---@param st changeset.State
---@param id string
---@return boolean
function M.is_collapsed(st, id)
  return st.collapsed[id] == true
end

---Fold or unfold a row's children.
---@param st changeset.State
---@param id string
---@param collapsed boolean
function M.set_collapsed(st, id, collapsed)
  st.collapsed[id] = collapsed or nil
end

---Fold every row in `ids`.
---@param st changeset.State
---@param ids string[]
function M.collapse_all(st, ids)
  for _, id in ipairs(ids) do
    st.collapsed[id] = true
  end
end

---Unfold every row, leaving opened chains as they are.
---@param st changeset.State
function M.expand_all(st)
  st.collapsed = {}
end

---Whether a compressed chain is being shown at full nesting.
---
---A separate axis from `collapsed`: compression hides a chain's *intermediate*
---rows, folding hides a row's children, and `l` on a compressed row means the
---first while `h` on a file means the second.
---@param st changeset.State
---@param id string
---@return boolean
function M.is_chain_open(st, id)
  return st.chains[id] == true
end

---Show or re-hide the intermediate rows of a compressed chain.
---@param st changeset.State
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

---What `h` does from a line: shut the row, or step out to its parent.
---
---Whether children are showing is read off the next line rather than the fold
---state, because a compressed chain shows them while it is itself still shut — so
---`h` closes one in the same two steps `l` opened it in.
---@param rows changeset.Row[] The visible rows, in display order.
---@param lnum integer 1-based; must index `rows`.
---@return "collapse"|"parent"|nil action nil on a shut row with no parent above it.
---@return integer? lnum 1-based line of the parent, when the action is "parent".
function M._outward(rows, lnum)
  local depth = rows[lnum].depth
  local below = rows[lnum + 1]
  if below and below.depth > depth then
    return "collapse"
  end
  for i = lnum - 1, 1, -1 do
    if rows[i].depth < depth then
      return "parent", i
    end
  end
end

return M
