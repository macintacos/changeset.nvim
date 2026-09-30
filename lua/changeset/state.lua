---View state that must survive a rebuild: where the cursor was, and which rows
---are folded. Both are keyed by row identity rather than by line, because a
---refresh reorders lines whenever the file set changes.
---
---The `_`-prefixed functions are pure decisions alongside it: where the cursor
---lands after a rebuild, where `h` goes from a row, where `]h`/`[h` and `]]`/`[[`
---step to, and which line stands in for a row that is not on screen.

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

---Unfold every row but those in `keep`, leaving opened chains as they are.
---@param st changeset.State
---@param keep string[] Ids whose fold stays as it is.
function M.expand_all(st, keep)
  local kept = {}
  for _, id in ipairs(keep) do
    kept[id] = st.collapsed[id]
  end
  st.collapsed = kept
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

---The line to put the cursor on after any redraw: the row it sat on, else, for a file row, the first file row
---with the same path (a file whose changes all turn out to be tests or comments moves to Tests or Docs; a filter
---can keep one copy and drop the others), else `fallback`.
---@param rows changeset.Row[] On screen, in display order.
---@param previous_row changeset.Row? The row the cursor sat on before the redraw.
---@param fallback integer Line to keep when nothing matches.
---@return integer lnum 1-based, always within `rows`.
function M._reanchor(rows, previous_row, fallback)
  local same_file
  for lnum, row in ipairs(rows) do
    if previous_row and row.id == previous_row.id then
      return lnum
    end
    if
      not same_file
      and previous_row
      and previous_row.kind == "file"
      and previous_row.depth == 1
      and row.kind == "file"
      and row.path == previous_row.path
    then
      same_file = lnum
    end
  end
  return same_file or math.max(1, math.min(fallback, #rows))
end

---The line showing the row with `id`, or else its deepest ancestor on screen.
---
---A row id extends its parent's by a `\0`-joined segment, so a row folded away,
---filtered out, or hidden inside a compressed chain (whose line carries the head's
---id) is stood in for by whichever of its ancestors is showing.
---@param ids string[] Row ids, in display order.
---@param id string
---@return integer? lnum 1-based; nil when nothing on screen is related.
function M._nearest(ids, id)
  local best, best_len = nil, 0
  for lnum, shown in ipairs(ids) do
    if #shown > best_len and vim.startswith(id, shown) and (#id == #shown or id:byte(#shown + 1) == 0) then
      best, best_len = lnum, #shown
    end
  end
  return best
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

---Where `]h`/`[h` go from a line: the nearest row past it in `delta`'s direction
---that is not a section header, or the line itself when there is none that way.
---@param rows changeset.Row[] The visible rows, in display order.
---@param lnum integer 1-based.
---@param delta integer 1 or -1.
---@return integer
function M._step(rows, lnum, delta)
  local i = lnum + delta
  while rows[i] and rows[i].kind == "section" do
    i = i + delta
  end
  return rows[i] and i or lnum
end

---Where `]]`/`[[` go from a line: the nearest section header past it in `delta`'s
---direction, a folded one included, or the line itself when there is none that way.
---@param rows changeset.Row[] The visible rows, in display order.
---@param lnum integer 1-based.
---@param delta integer 1 or -1.
---@return integer
function M._section(rows, lnum, delta)
  local i = lnum + delta
  while rows[i] and rows[i].kind ~= "section" do
    i = i + delta
  end
  return rows[i] and i or lnum
end

return M
