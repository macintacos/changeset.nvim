---Loading the files the sidebar reads.
---
---The sidebar opens files the user did not ask for: to read their symbols, and
---to preview a row. Both must be silent and neither may fail loudly, so both go
---through here.

local M = {}

---Load `path` into an unlisted buffer.
---
---Unlisted because the user did not open these files: they must stay out of
---`:ls`, the buffer picker, and the session file until a commit promotes one.
---
---`shortmess+=A` is the load-bearing part. A changed file that is already open
---in another Neovim has a swap file, and `bufload` on it raises `E325:
---ATTENTION` — a modal prompt in an interactive session, and an error that
---aborts whatever loop is walking the file list. Reading a file to describe it
---is not an edit session, so the warning has nothing to tell us.
---@param path string Absolute path.
---@return integer? bufnr nil when the path is not a readable file.
function M.load(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local buf = vim.fn.bufadd(path)
  vim.bo[buf].buflisted = false
  if vim.api.nvim_buf_is_loaded(buf) then
    return buf
  end

  local saved = vim.o.shortmess
  vim.opt.shortmess:append("A")
  local ok = pcall(vim.fn.bufload, buf)
  vim.o.shortmess = saved
  return ok and buf or nil
end

return M
