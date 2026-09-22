---Asking language servers for the symbols of files the branch touched.
---
---This is the I/O shell: it loads buffers, waits for clients, and hands the
---flattened trees back. Everything it learns goes to `changeset.tree`, which does
---the thinking without touching the editor.

local buffers = require("plugins.changeset.buffers")
local kinds = require("plugins.mini-pickers.kinds")
local symbols = require("plugins.mini-pickers.symbols")

-- Resolving every changed file at once would open forty buffers and fire forty
-- requests in the same tick. Walking the list a few at a time costs nothing and
-- makes the tree fill in reading order, which is the order it is being read in.
local CONCURRENCY = 4

-- A server that never attaches (no client for the filetype) must not leave the
-- file showing its resolving placeholder forever.
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

---@param bufnr integer
---@param on_client fun(ok: boolean)
local function await_client(bufnr, on_client)
  local method = "textDocument/documentSymbol"
  if #vim.lsp.get_clients({ bufnr = bufnr, method = method }) > 0 then
    return on_client(true)
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
---@param path string
---@param on_done fun(items: MiniPickers.Symbol[]?)
local function request(bufnr, path, on_done)
  -- The attach wait ends in a timer or an autocommand, by which time a `:bwipeout`
  -- or another plugin's buffer sweep may have taken this one. Answering nothing
  -- keeps the walk pumping; raising here would strand one of its four lanes.
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return on_done(nil)
  end
  local keep = kinds.for_filetype(vim.bo[bufnr].filetype)
  local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  vim.lsp.buf_request_all(bufnr, "textDocument/documentSymbol", params, function(results)
    local items = {}
    for id, res in pairs(results) do
      local client = vim.lsp.get_client_by_id(id)
      vim.list_extend(
        items,
        symbols.flatten(res.result or {}, {
          bufnr = bufnr,
          path = path,
          kinds = keep,
          encoding = client and client.offset_encoding,
        })
      )
    end
    on_done(items)
  end)
end

---Load `path` without listing it, then resolve its symbols.
---@param root string Repo root the paths are relative to.
---@param path string
---@param on_done fun(items: MiniPickers.Symbol[]?)
local function resolve_one(root, path, on_done)
  local bufnr = buffers.load(root .. "/" .. path)
  if not bufnr then
    return on_done(nil)
  end
  await_client(bufnr, function(ok)
    if not ok then
      return on_done(nil)
    end
    request(bufnr, path, on_done)
  end)
end

---Walk a queue of paths through `run`, at most `CONCURRENCY` of them in flight, reporting
---each answer as it lands. A `run` that raises before answering is reported as no symbols,
---so a failing step closes its lane instead of stranding it.
---@param queue string[]
---@param run fun(path: string, done: fun(items: MiniPickers.Symbol[]?))
---@param on_file fun(path: string, items: MiniPickers.Symbol[]?)
---@return fun() cancel
function M._walk(queue, run, on_file)
  local next_index, cancelled = 1, false

  local function pump()
    if cancelled or next_index > #queue then
      return
    end
    local path = queue[next_index]
    next_index = next_index + 1
    local function step(items)
      if cancelled then
        return
      end
      on_file(path, items)
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

---Resolve every changed file's symbols, reporting each as it lands.
---@param root string
---@param files changeset.File[]
---@param on_file fun(path: string, items: MiniPickers.Symbol[]?)
---@return fun() cancel
function M.start(root, files, on_file)
  return M._walk(M._resolvable(files), function(path, done)
    resolve_one(root, path, done)
  end, on_file)
end

return M
