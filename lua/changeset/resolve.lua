---Asking language servers for the symbols of files the branch touched, and reading which of their lines are
---comments at the base and now.
---
---This is the I/O shell: it loads buffers, reads base blobs, waits for clients, and hands the
---flattened trees and comment lines back. Everything it learns goes to `changeset.tree`, which does
---the thinking without touching the editor.

local attributes = require("changeset.attributes")
local buffers = require("changeset.buffers")
local comments = require("changeset.comments")
local diff = require("changeset.diff")
local kinds = require("changeset.kinds")
local sections = require("changeset.sections")
local symbols = require("changeset.symbols")

-- Resolving every changed file at once would open forty buffers and fire forty
-- requests in the same tick. Walking the list a few at a time costs nothing and
-- makes the tree fill in reading order, which is the order it is being read in.
local CONCURRENCY = 4

-- An enabled server that never attaches (binary missing, no root found) must not
-- leave the file showing its resolving placeholder forever.
local ATTACH_TIMEOUT_MS = 2000

local M = {}

---Paths worth asking a server about, in display order.
---@param files changeset.File[]
---@return string[]
function M._resolvable(files)
  local out = {}
  for _, file in ipairs(files) do
    if file.status ~= "deleted" then
      out[#out + 1] = file.path
    end
  end
  return out
end

---Whether a server enabled through `vim.lsp.enable` may yet attach to `bufnr`. One
---started by hand is missed, but the sidebar asks again once it attaches.
---@param bufnr integer
---@return boolean
local function server_expected(bufnr)
  local filetype = vim.bo[bufnr].filetype
  return vim.iter(vim.lsp.get_configs({ enabled = true })):any(function(config)
    return not config.filetypes or vim.list_contains(config.filetypes, filetype)
  end)
end

---@param bufnr integer
---@param on_client fun(ok: boolean)
local function await_client(bufnr, on_client)
  local method = "textDocument/documentSymbol"
  if #vim.lsp.get_clients({ bufnr = bufnr, method = method }) > 0 then
    return on_client(true)
  end
  if not server_expected(bufnr) then
    return on_client(false)
  end

  local done = false
  local group = vim.api.nvim_create_augroup("ChangesetAttach" .. bufnr, { clear = true })
  local function finish(ok)
    if done then
      return
    end
    done = true
    pcall(vim.api.nvim_del_augroup_by_id, group)
    on_client(ok)
  end

  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    buffer = bufnr,
    desc = "changeset: a server reached a changed file, so its symbols can be requested",
    callback = function()
      vim.schedule(function()
        finish(#vim.lsp.get_clients({ bufnr = bufnr, method = method }) > 0)
      end)
    end,
  })
  vim.defer_fn(function()
    finish(false)
  end, ATTACH_TIMEOUT_MS)
end

---Flattened symbols for one loaded buffer.
---@param bufnr integer
---@param on_done fun(items: changeset.Symbol[])
local function request(bufnr, on_done)
  local keep = kinds.for_filetype(vim.bo[bufnr].filetype)
  local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  vim.lsp.buf_request_all(bufnr, "textDocument/documentSymbol", params, function(results)
    local items = {}
    for _, res in pairs(results) do
      vim.list_extend(items, symbols.flatten(res.result or {}, keep))
    end
    on_done(items)
  end)
end

---The file's text at `repo.base`, or nil when it has no base side or git cannot read it.
---@param repo changeset.resolve.Repo
---@param file changeset.File
---@param on_text fun(text: string?)
local function read_base(repo, file, on_text)
  local base_path = file.status == "renamed" and file.oldpath or file.status == "modified" and file.path
  if not base_path then
    return on_text(nil)
  end
  diff.blob(repo.base .. ":" .. base_path, repo.root, on_text)
end

---Load `file` without listing it, then resolve its symbols and comment lines.
---@param repo changeset.resolve.Repo
---@param file changeset.File
---@param on_done fun(items: changeset.Symbol[]?, comments: changeset.Comments?)
local function resolve_one(repo, file, on_done)
  local path = file.path
  local bufnr = buffers.load(repo.root .. "/" .. path)
  if not bufnr then
    return on_done(nil)
  end
  -- A Docs file lists whole, so its comment lines would be read for nothing.
  local docs = sections.classify(path, file.generated) == "docs"
  local function read(on_text)
    if docs then
      return on_text(nil)
    end
    read_base(repo, file, on_text)
  end
  read(function(old_text)
    await_client(bufnr, function(ok)
      -- The buffer may have been wiped during the waits; answering nothing keeps the walk
      -- pumping, where raising would strand one of its four lanes.
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return on_done(nil)
      end
      -- One snapshot for both readers: symbol lines and comment lines have to agree, and an
      -- unwritten edit would move either away from the file on disk.
      local source = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
      local new = not docs and comments.read(source, path) or nil
      local found = new and { new = new, old = old_text and comments.read(old_text, file.oldpath or path) }
      if not ok then
        return on_done(nil, found)
      end
      request(bufnr, function(items)
        attributes.mark(items, path, source)
        on_done(items, found)
      end)
    end)
  end)
end

---Walk a queue of paths through `run`, at most `CONCURRENCY` of them in flight, reporting
---each answer as it lands. A `run` that raises before answering is reported as no symbols,
---so a failing step closes its lane instead of stranding it.
---@param queue string[]
---@param run fun(path: string, done: fun(items: changeset.Symbol[]?, comments: changeset.Comments?))
---@param on_file fun(path: string, items: changeset.Symbol[]?, comments: changeset.Comments?)
---@return fun() cancel Starts no further file; one already in flight is still reported.
function M._walk(queue, run, on_file)
  local next_index, cancelled = 1, false

  local function pump()
    if cancelled or next_index > #queue then
      return
    end
    local path = queue[next_index]
    next_index = next_index + 1
    -- The pcall below also catches a raise arriving after `run` has answered, and
    -- pumping twice for one lane would put more than CONCURRENCY in flight.
    local answered = false
    local function step(items, found)
      if answered then
        return
      end
      answered = true
      on_file(path, items, found)
      pump()
    end
    if not pcall(run, path, step) then
      step(nil)
    end
  end

  for _ = 1, math.min(CONCURRENCY, #queue) do
    pump()
  end

  return function()
    cancelled = true
  end
end

---@class changeset.resolve.Repo
---@field root string Repo root the paths are relative to.
---@field base string Commit the files' base sides are read from.

---Resolve every changed file's symbols and comment lines, reporting each as it lands. Each item carries `test`
---when its syntax marks it an inline test.
---@param repo changeset.resolve.Repo
---@param files changeset.File[]
---@param on_file fun(path: string, items: changeset.Symbol[]?, comments: changeset.Comments?)
---@return fun() cancel
function M.start(repo, files, on_file)
  local by_path = {}
  for _, file in ipairs(files) do
    by_path[file.path] = file
  end
  return M._walk(M._resolvable(files), function(path, done)
    resolve_one(repo, by_path[path], done)
  end, on_file)
end

return M
