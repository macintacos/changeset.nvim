---An in-process language server, one per repository, whose client is named `changeset` and which answers only hover.
local M = {}

-- README states the name, so a hover UI can sort on it.
local NAME = "changeset"

---@alias changeset.hover.Answer fun(fname: string, lnum: integer): string? Markdown for line `lnum` (1-based) of `fname`.

---@param answer changeset.hover.Answer
---@return fun(dispatchers: vim.lsp.rpc.Dispatchers): vim.lsp.rpc.PublicClient
local function server(answer)
  ---@type table<string, fun(params: table): any>
  local methods = {
    initialize = function()
      return { capabilities = { hoverProvider = true } }
    end,
    shutdown = function() end,
    ["textDocument/hover"] = function(params)
      local value = answer(vim.uri_to_fname(params.textDocument.uri), params.position.line + 1)
      return value and { contents = { kind = vim.lsp.protocol.MarkupKind.Markdown, value = value } }
    end,
  }
  return function(dispatchers)
    local closing, request_id = false, 0
    return {
      request = function(method, params, callback, notify_reply_callback)
        request_id = request_id + 1
        local handle = methods[method]
        -- Answered at once, so the client must hear it is no longer pending or it lists it forever.
        if notify_reply_callback then
          notify_reply_callback(request_id)
        end
        if handle then
          callback(nil, handle(params), request_id)
        else
          callback(vim.lsp.rpc.rpc_response_error(vim.lsp.protocol.ErrorCodes.MethodNotFound), nil, request_id)
        end
        return true, request_id
      end,
      notify = function(method)
        if method == "exit" then
          dispatchers.on_exit(0, 15)
        end
        return true
      end,
      is_closing = function()
        return closing
      end,
      terminate = function()
        closing = true
      end,
    }
  end
end

---What attaches a file buffer to its repository's `changeset` client, started on first use and answering hover with `answer`.
---@param answer changeset.hover.Answer
---@return fun(buf: integer, root: string)
function M.serve(answer)
  local cmd = server(answer)
  return function(buf, root)
    if vim.bo[buf].buftype == "" then
      vim.lsp.start({ name = NAME, cmd = cmd, root_dir = root }, { bufnr = buf })
    end
  end
end

return M
