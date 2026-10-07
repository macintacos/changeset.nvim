local Fixture = require("support.git")
local comment_store = require("changeset.comment_store")
require("changeset.review_comments")

---@param count integer
---@param name string
local function lines(count, name)
  local out = {}
  for i = 1, count do
    out[i] = name .. " " .. i
  end
  return out
end

---@param buf integer
---@return vim.lsp.Client[]
local function clients(buf)
  return vim.lsp.get_clients({ bufnr = buf, name = "changeset" })
end

---The `changeset` client's hover markdown for line `lnum` of `buf`, nil when it answers none.
---@param buf integer
---@param lnum integer
---@return string?
local function hover(buf, lnum)
  local client = assert(clients(buf)[1])
  local params = { textDocument = { uri = vim.uri_from_bufnr(buf) }, position = { line = lnum - 1, character = 0 } }
  local results = assert(vim.lsp.buf_request_sync(buf, "textDocument/hover", params, 1000))
  local result = assert(results[client.id]).result
  return result and result.contents.value
end

describe("hover", function()
  local dir, alpha

  ---Replaces the repository's review comments with `comments`.
  ---@param comments changeset.ReviewComment[]
  local function set(comments)
    comment_store.drop_all(dir)
    for _, comment in ipairs(comments) do
      comment_store.keep(dir, comment)
    end
  end

  local RANGE = { path = "alpha.txt", line = 10, start_line = 8, body = "range body" }
  local SINGLE = { path = "alpha.txt", line = 20, body = "saved body" }
  local BETA = { path = "beta.txt", line = 5, body = "beta body" }

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    dir = vim.fs.normalize(assert(vim.uv.fs_realpath(dir)))
    Fixture.init_repo("main", dir)
    os.remove(comment_store.path())
    vim.fn.writefile(lines(40, "alpha"), dir .. "/alpha.txt")
    vim.fn.writefile(lines(20, "beta"), dir .. "/beta.txt")
    vim.cmd.edit(dir .. "/alpha.txt")
    alpha = vim.api.nvim_get_current_buf()
  end)

  after_each(function()
    vim.cmd("silent! %bwipeout!")
    os.remove(comment_store.path())
    for _, client in ipairs(vim.lsp.get_clients({ name = "changeset" })) do
      client:stop(true)
    end
    vim.fn.delete(dir, "rf")
  end)

  it("attaches a client named changeset to a file with a review comment", function()
    set({ RANGE, SINGLE, BETA })
    assert.are.equal(1, #clients(alpha))
  end)

  it("shares one client among a repository's files", function()
    vim.cmd.edit(dir .. "/beta.txt")
    local beta = vim.api.nvim_get_current_buf()
    set({ RANGE, SINGLE, BETA })
    assert.are.equal(assert(clients(alpha)[1]).id, assert(clients(beta)[1]).id)
  end)

  it("answers hover with a review comment's lines and body on every line of its range", function()
    set({ RANGE, SINGLE, BETA })
    assert.are.equal("**Review comment · lines 8-10**\n\nrange body", hover(alpha, 8))
    assert.are.equal("**Review comment · lines 8-10**\n\nrange body", hover(alpha, 9))
  end)

  it("heads a draft's hover as a draft", function()
    set({ { path = "alpha.txt", line = 9, body = "unsure", draft = true } })
    assert.are.equal("**Draft review comment · line 9**\n\nunsure", hover(alpha, 9))
  end)

  it("answers hover with every review comment covering the line", function()
    set({ RANGE, { path = "alpha.txt", line = 9, body = "inner" } })
    assert.are.equal(
      "**Review comment · lines 8-10**\n\nrange body\n\n---\n\n**Review comment · line 9**\n\ninner",
      hover(alpha, 9)
    )
  end)

  it("marks a file read after its comments were kept", function()
    set({ BETA })
    vim.cmd.edit(dir .. "/beta.txt")
    assert.are.equal("**Review comment · line 5**\n\nbeta body", hover(vim.api.nvim_get_current_buf(), 5))
  end)

  it("answers nothing on a line without a review comment", function()
    set({ RANGE, SINGLE, BETA })
    assert.is_nil(hover(alpha, 1))
  end)

  it("drops the carriage returns of a CRLF body", function()
    set({ vim.tbl_extend("force", SINGLE, { body = "first\r\nsecond" }) })
    assert.are.equal("**Review comment · line 20**\n\nfirst\nsecond", hover(alpha, 20))
  end)

  it("detaches a buffer whose last review comment is deleted", function()
    set({ RANGE, BETA })
    set({ BETA })
    assert.are.same({}, clients(alpha))
  end)

  it("keeps a buffer attached while it has a review comment", function()
    set({ RANGE, SINGLE })
    comment_store.drop(dir, RANGE)
    assert.are.equal(1, #clients(alpha))
  end)

  it("stops the client once no buffer is attached to it", function()
    set({ RANGE })
    set({})
    assert.is_true(vim.wait(1000, function()
      return #vim.lsp.get_clients({ name = "changeset" }) == 0
    end, 10))
  end)

  it("gives K back to 'keywordprg' on a detached buffer no other server has hover for", function()
    set({ RANGE })
    set({})
    assert.are.same({}, vim.fn.maparg("K", "n", false, true))
  end)

  it("leaves K to another server that has hover on a detached buffer", function()
    vim.lsp.start({
      name = "other",
      root_dir = dir,
      cmd = function(dispatchers)
        return {
          request = function(method, _, callback)
            callback(nil, method == "initialize" and { capabilities = { hoverProvider = true } } or nil)
            return true, 1
          end,
          notify = function(method)
            if method == "exit" then
              dispatchers.on_exit(0, 15)
            end
            return true
          end,
          is_closing = function()
            return false
          end,
          terminate = function() end,
        }
      end,
    }, { bufnr = alpha })
    set({ RANGE })
    set({})
    assert.are.equal("vim.lsp.buf.hover()", vim.fn.maparg("K", "n", false, true).desc)
    for _, client in ipairs(vim.lsp.get_clients({ name = "other" })) do
      client:stop()
    end
  end)

  it("attaches no client to a buffer that is not a file", function()
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(scratch, dir .. "/beta.txt")
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, lines(20, "beta"))
    set({ RANGE, SINGLE, BETA })
    assert.are.same({}, clients(scratch))
  end)

  for _, force in ipairs({ false, true }) do
    it(("leaves no client behind once stopped%s"):format(force and " by force" or ""), function()
      set({ RANGE, SINGLE, BETA })
      local client = assert(clients(alpha)[1])
      client:stop(force)
      assert.is_true(vim.wait(1000, function()
        return vim.lsp.get_client_by_id(client.id) == nil
      end, 10))
    end)
  end
end)
