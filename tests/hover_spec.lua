local tree, found, on_tree, on_answer

package.loaded["changeset.build"] = {
  current = function()
    return tree
  end,
  subscribe = function(fn)
    on_tree = fn
  end,
}
package.loaded["changeset.pending_state"] = {
  get = function(root, number)
    if tree and root == tree.root and number == tree.pr and number == 1 then
      return found
    end
  end,
  subscribe = function(fn)
    on_answer = fn
  end,
}

require("changeset.review_comments")
local drafts = require("changeset.drafts")

local PR = { id = "PR_1", number = 1, host = "github.com", owner = "o", name = "n", head = "h" }

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

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    dir = vim.fs.normalize(assert(vim.uv.fs_realpath(dir)))
    vim.fn.writefile(lines(40, "alpha"), dir .. "/alpha.txt")
    vim.fn.writefile(lines(20, "beta"), dir .. "/beta.txt")
    tree = { root = dir, branch = "b", pr = 1 }
    found = {
      pr = PR,
      review = {
        id = "R1",
        comments = {
          { id = "PRRC_1", path = "alpha.txt", line = 10, start_line = 8, body = "range body" },
          { id = "PRRC_2", path = "alpha.txt", line = 20, body = "saved body" },
          { id = "PRRC_3", path = "beta.txt", line = 5, body = "beta body" },
        },
      },
    }
    vim.cmd.edit(dir .. "/alpha.txt")
    alpha = vim.api.nvim_get_current_buf()
  end)

  after_each(function()
    vim.cmd("silent! %bwipeout!")
    os.remove(drafts.path())
    for _, client in ipairs(vim.lsp.get_clients({ name = "changeset" })) do
      client:stop(true)
    end
    vim.fn.delete(dir, "rf")
  end)

  it("attaches a client named changeset to a file with a review comment", function()
    on_answer()
    assert.are.equal(1, #clients(alpha))
  end)

  it("shares one client among a repository's files", function()
    vim.cmd.edit(dir .. "/beta.txt")
    local beta = vim.api.nvim_get_current_buf()
    on_answer()
    assert.are.equal(assert(clients(alpha)[1]).id, assert(clients(beta)[1]).id)
  end)

  it("answers hover with a review comment's lines and body on every line of its range", function()
    on_answer()
    assert.are.equal("**Review comment · lines 8-10**\n\nrange body", hover(alpha, 8))
    assert.are.equal("**Review comment · lines 8-10**\n\nrange body", hover(alpha, 9))
  end)

  it("says a draft is only on this machine", function()
    drafts.keep(PR, { path = "alpha.txt", line = 31, start_line = 30, head = "h", body = "draft body" })
    assert.are.equal("**Draft · lines 30-31 · only on this machine**\n\ndraft body", hover(alpha, 31))
  end)

  it("puts a line's review comments before its drafts", function()
    drafts.keep(PR, { path = "alpha.txt", line = 20, head = "h", body = "draft body" })
    assert.are.equal(
      "**Review comment · line 20**\n\nsaved body\n\n---\n\n**Draft · line 20 · only on this machine**\n\ndraft body",
      hover(alpha, 20)
    )
  end)

  it("answers nothing on a line without a review comment or draft", function()
    on_answer()
    assert.is_nil(hover(alpha, 1))
  end)

  it("drops the carriage returns of a CRLF body", function()
    found.review.comments[2].body = "first\r\nsecond"
    on_answer()
    assert.are.equal("**Review comment · line 20**\n\nfirst\nsecond", hover(alpha, 20))
  end)

  it("answers nothing once the tree is on a PR GitHub hasn't answered for", function()
    on_answer()
    tree = { root = dir, branch = "c", pr = 2 }
    on_tree("pr")
    assert.is_nil(hover(alpha, 20))
  end)

  it("attaches no client to a buffer that is not a file", function()
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(scratch, dir .. "/beta.txt")
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, lines(20, "beta"))
    on_answer()
    assert.are.same({}, clients(scratch))
  end)

  it("attaches no client while the tree has no PR", function()
    vim.cmd("%bwipeout!")
    tree = { root = dir, branch = "c" }
    on_tree("pr")
    vim.cmd.edit(dir .. "/alpha.txt")
    assert.are.same({}, clients(vim.api.nvim_get_current_buf()))
  end)

  it("leaves no client behind once stopped", function()
    on_answer()
    local client = assert(clients(alpha)[1])
    client:stop()
    assert.is_true(vim.wait(1000, function()
      return vim.lsp.get_client_by_id(client.id) == nil
    end, 10))
  end)
end)
