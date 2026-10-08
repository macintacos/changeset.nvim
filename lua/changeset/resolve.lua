---Asking language servers for the symbols of files the branch touched, and reading which of their lines are
---comments at the base and now.
---
---This is the I/O shell: it loads buffers, reads base blobs, waits for clients, and hands the
---flattened trees and comment lines back. Everything it learns goes to `changeset.rows`, which does
---the thinking without touching the editor.

local attributes = require("changeset.attributes")
local buffers = require("changeset.buffers")
local comments = require("changeset.comments")
local diff = require("changeset.diff")
local kinds = require("changeset.kinds")
local symbols = require("changeset.symbols")

-- Resolving every changed file at once would open forty buffers and fire forty
-- requests in the same tick. Walking the list a few at a time costs nothing and
-- makes the tree fill in reading order, which is the order it is being read in.
local CONCURRENCY = 4

-- An enabled server that never attaches (binary missing, no root found) must not
-- leave the file showing its resolving placeholder forever.
local ATTACH_TIMEOUT_MS = 2000

-- A server that never answers, a hung one say, must not strand a walk lane.
local REQUEST_TIMEOUT_MS = 10000

local M = {}

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
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return on_client(false)
  end
  if #vim.lsp.get_clients({ bufnr = bufnr, method = method }) > 0 then
    return on_client(true)
  end
  if not server_expected(bufnr) then
    return on_client(false)
  end

  -- Each wait owns its autocmd: a second walk waiting on the same file must not
  -- silence the first's.
  local done, autocmd = false, nil
  local function finish(ok)
    if done then
      return
    end
    done = true
    pcall(vim.api.nvim_del_autocmd, autocmd)
    on_client(ok)
  end

  autocmd = vim.api.nvim_create_autocmd("LspAttach", {
    buffer = bufnr,
    desc = "changeset: a server reached a changed file, so its symbols can be requested",
    callback = function(args)
      -- A client that lists no symbols, such as changeset's hover, attaching first would mark the file as having no server.
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if not (client and client:supports_method(method)) then
        return
      end
      vim.schedule(function()
        finish(#vim.lsp.get_clients({ bufnr = bufnr, method = method }) > 0)
      end)
    end,
  })
  vim.defer_fn(function()
    finish(false)
  end, ATTACH_TIMEOUT_MS)
end

---Flattened symbols for one loaded buffer, from the first client that listed any, else the
---first that answered without an error, or nil when none did.
---@param bufnr integer
---@param on_done fun(items: changeset.Symbol[]?, timed_out: boolean?) `timed_out` when a client was still answering.
local function request(bufnr, on_done)
  local method = "textDocument/documentSymbol"
  local keep = kinds.for_filetype(vim.bo[bufnr].filetype)
  local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = method })
  local waiting, answers, pending, done, autocmd = {}, {}, 0, false, nil

  local function finish(timed_out)
    if done then
      return
    end
    done = true
    pcall(vim.api.nvim_del_autocmd, autocmd)
    -- A server with nothing for this file answers []; another may still list its symbols.
    local answered = vim
      .iter(clients)
      :map(function(client)
        return answers[client.id]
      end)
      :totable()
    local items = vim.iter(answered):find(function(listed)
      return #listed > 0
    end) or answered[1]
    on_done(items, timed_out and items == nil)
  end

  local function settle(id, items)
    if done or not waiting[id] then
      return
    end
    waiting[id], answers[id], pending = nil, items, pending - 1
    if pending == 0 then
      finish()
    end
  end

  -- Fires: a client leaves the buffer, which on exit drops its pending handlers
  -- without calling them.
  autocmd = vim.api.nvim_create_autocmd("LspDetach", {
    buffer = bufnr,
    desc = "changeset: stop waiting on a client that left before answering for symbols",
    callback = function(args)
      settle(args.data.client_id, nil)
    end,
  })
  for _, client in ipairs(clients) do
    waiting[client.id], pending = true, pending + 1
    local sent = client:request(method, params, function(err, result)
      local ok, items = pcall(symbols.flatten, result or {}, keep)
      settle(client.id, not err and ok and items or nil)
    end, bufnr)
    if not sent then
      settle(client.id, nil)
    end
  end
  if pending == 0 then
    return finish()
  end
  vim.defer_fn(function()
    finish(true)
  end, REQUEST_TIMEOUT_MS)
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

---The comment lines of a file's text now and at its base, and the parse of its text now.
---@param source string? nil when its comment lines go unread.
---@param path string
---@param old_text string?
---@param old_path string
---@param on_done fun(comment_lines: changeset.Comments?, parsed: changeset.Parsed?)
local function read_comments(source, path, old_text, old_path, on_done)
  if not source then
    return on_done(nil)
  end
  comments.read(source, path, function(new_kinds, parsed)
    if not (new_kinds and old_text) then
      return on_done(new_kinds and { new = new_kinds }, parsed)
    end
    comments.read(old_text, old_path, function(old_kinds)
      on_done({ new = new_kinds, old = old_kinds }, parsed)
    end)
  end)
end

---Load `file` without listing it, then resolve its symbols and comment lines.
---@param repo changeset.resolve.Repo
---@param file changeset.File
---@param on_done fun(items: changeset.Symbol[]?, comments: changeset.Comments?, timed_out: boolean?)
local function resolve_one(repo, file, on_done)
  local path = file.path
  local bufnr = buffers.load(repo.root .. "/" .. path)
  if not bufnr then
    return on_done(nil)
  end
  -- A Docs file lists whole, so its comment lines would be read for nothing.
  local is_docs_file = file.section == "docs"
  local function read(on_text)
    if is_docs_file then
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
      read_comments(
        not is_docs_file and source or nil,
        path,
        old_text,
        file.oldpath or path,
        function(comment_lines, parsed)
          if not ok then
            return on_done(nil, comment_lines)
          end
          -- Parsing in slices lets the buffer be wiped before the server is asked.
          if not vim.api.nvim_buf_is_valid(bufnr) then
            return on_done(nil)
          end
          request(bufnr, function(items, timed_out)
            if items then
              attributes.mark(items, path, source, parsed)
            end
            on_done(items, comment_lines, timed_out)
          end)
        end
      )
    end)
  end)
end

---Walk a queue of paths through `run`, at most `CONCURRENCY` of them in flight, reporting
---each answer as it lands. A `run` that raises before answering is reported as no symbols,
---so a failing step closes its lane instead of stranding it.
---@param queue string[]
---@param run fun(path: string, done: fun(items: changeset.Symbol[]?, comments: changeset.Comments?, timed_out: boolean?))
---@param on_file fun(path: string, items: changeset.Symbol[]?, comments: changeset.Comments?, timed_out: boolean?)
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
    local function step(items, comment_lines, timed_out)
      if answered then
        return
      end
      answered = true
      on_file(path, items, comment_lines, timed_out)
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
---@param files changeset.File[] Only files whose symbols are read (`Rows.skips`), in display order.
---@param on_file fun(path: string, items: changeset.Symbol[]?, comments: changeset.Comments?, timed_out: boolean?)
---`timed_out` when no server answered in time, as opposed to none answering at all.
---@return fun() cancel
function M.start(repo, files, on_file)
  local file_by_path = {}
  for _, file in ipairs(files) do
    file_by_path[file.path] = file
  end
  return M._walk(
    vim.tbl_map(function(file)
      return file.path
    end, files),
    function(path, done)
      resolve_one(repo, file_by_path[path], done)
    end,
    on_file
  )
end

return M
