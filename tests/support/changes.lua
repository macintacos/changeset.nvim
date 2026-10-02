---Inputs for `Rows.build`: changed files and the symbols read from them.

local M = {}

---A flat `changeset.Symbol` as `symbols.flatten` returns it, its body spanning `first..last`.
---@param name string
---@param kind string
---@param depth integer
---@param first integer
---@param last integer
---@return table
function M.sym(name, kind, depth, first, last)
  return {
    name = name,
    kind = kind,
    lnum = first,
    depth = depth,
    range_lnum = first,
    range_end_lnum = last,
  }
end

---A file whose diff adds one line at each of `lines`.
---@param path string
---@param lines integer[]
---@return changeset.File
function M.file(path, lines)
  local hunks = vim.tbl_map(function(lnum)
    return { lnum = lnum, count = 1, added = 1, removed = 0 }
  end, lines)
  return { path = path, status = "modified", added = #lines, removed = 0, hunks = hunks }
end

return M
