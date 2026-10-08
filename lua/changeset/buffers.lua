---Loading the files the sidebar reads.
---
---The sidebar opens files the user did not ask for: to read their symbols, and
---to preview a row. Both must be silent and neither may fail loudly, so both go
---through here.

local M = {}

---The loaded buffer of the file at `path`, if any.
---@param path string Absolute.
---@return integer?
function M.loaded(path)
  local full = vim.fs.normalize(path)
  -- Not `bufnr(path)`: it takes a pattern, and settles for another file the pattern matches.
  return vim.iter(vim.api.nvim_list_bufs()):find(function(b)
    return vim.api.nvim_buf_is_loaded(b) and vim.fs.normalize(vim.api.nvim_buf_get_name(b)) == full
  end)
end

---Load `path` into a buffer, without disturbing one the user already has.
---
---`bufadd` leaves a buffer it creates unlisted, which is what keeps the files
---only the sidebar opened out of `:ls`, the buffer picker and the session file
---until a commit promotes one. It returns an existing buffer untouched, and a
---buffer the user opened is theirs to list.
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
  if vim.api.nvim_buf_is_loaded(buf) then
    return buf
  end

  local saved = vim.o.shortmess
  vim.opt.shortmess:append("A")
  local ok = pcall(vim.cmd --[[@as fun(command: string)]], ("noswapfile call bufload(%d)"):format(buf))
  vim.o.shortmess = saved
  if not ok then
    return nil
  end
  -- A swap file would make a second Neovim warn about a file only read here. It
  -- comes back once the buffer is the user's, so their edits keep crash recovery.
  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = buf,
    once = true,
    desc = "changeset: give a buffer the sidebar loaded its swap file once the user enters it",
    callback = function()
      vim.bo[buf].swapfile = vim.go.swapfile
    end,
  })

  -- Autocommands do not nest, and the sidebar previews from a `CursorMoved`
  -- callback: the read above then skips the `BufRead` chain that names a
  -- filetype, and a buffer without one gets no treesitter, no syntax, and no
  -- language server. Naming it here fires `FileType` itself, which is what all
  -- three attach to; review comment marks get their `BufReadPost` the same way.
  if vim.bo[buf].filetype == "" then
    vim.bo[buf].filetype = vim.filetype.match({ buf = buf }) or vim.bo[buf].filetype
  end
  if vim.fn.exists("#changeset.review_comments#BufReadPost") == 1 then
    vim.api.nvim_exec_autocmds("BufReadPost", { group = "changeset.review_comments", buffer = buf, modeline = false })
  end
  return buf
end

return M
