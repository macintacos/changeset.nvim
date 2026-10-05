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

local review_comments = require("changeset.review_comments")
local config = require("changeset.config")
local drafts = require("changeset.drafts")
local render = require("changeset.render")

---@param path string
---@param line integer?
---@param start_line integer?
local function comment(path, line, start_line)
  return { id = "PRRC_" .. path .. tostring(line), path = path, line = line, start_line = start_line, body = "b" }
end

local function full_answer()
  return {
    pr = { id = "PR_1", number = 1 },
    review = {
      id = "R1",
      comments = {
        comment("alpha.txt", 31),
        comment("alpha.txt", 13),
        comment("alpha.txt", 10, 8),
        comment("alpha.txt", 31, 10),
        comment("beta.txt", 16),
        comment("alpha.txt", nil),
      },
    },
  }
end

---@param buf integer
local function marks(buf)
  local ns = vim.api.nvim_get_namespaces()["changeset.review_comments"]
  return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
end

---@param buf integer
---@return integer[][]
local function rows(buf)
  return vim.tbl_map(function(mark)
    return { mark[2], mark[4].end_row }
  end, marks(buf))
end

---Each sign's row, text and group, found the way a statuscolumn would find them.
---@param buf integer
---@return table[]
local function signs(buf)
  local ns = vim.api.nvim_create_namespace("changeset.review_comment_signs")
  return vim.tbl_map(function(mark)
    return { mark[2], mark[4].sign_text, mark[4].sign_hl_group }
  end, vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }))
end

---The sign text of every extmark in `buf`, whatever its namespace.
---@param buf integer
---@return string[]
local function sign_texts(buf)
  return vim
    .iter(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true }))
    :map(function(mark)
      return mark[4].sign_text
    end)
    :totable()
end

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

describe("review_comments", function()
  local dir, other, alpha, beta

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    dir = vim.fs.normalize(assert(vim.uv.fs_realpath(dir)))
    vim.fn.writefile(lines(40, "alpha"), dir .. "/alpha.txt")
    vim.fn.writefile(lines(20, "beta"), dir .. "/beta.txt")
    tree = { root = dir, branch = "b", pr = 1 }
    found = nil
    vim.cmd.edit(dir .. "/alpha.txt")
    alpha = vim.api.nvim_get_current_buf()
    vim.cmd.edit(dir .. "/beta.txt")
    beta = vim.api.nvim_get_current_buf()
  end)

  after_each(function()
    config.setup()
    vim.cmd("silent! %bwipeout!")
    os.remove(drafts.path())
    vim.fn.delete(dir, "rf")
    if other then
      vim.fn.delete(other, "rf")
      other = nil
    end
  end)

  it("marks open buffers once an answer is kept", function()
    found = full_answer()
    on_answer()
    assert.are.same({ { 7, 9 }, { 9, 30 }, { 12, 12 }, { 30, 30 } }, rows(alpha))
    assert.are.same({ { 15, 15 } }, rows(beta))
  end)

  it("marks a buffer opened after the answer from the kept answer", function()
    found = full_answer()
    on_answer()
    vim.cmd("%bwipeout!")
    vim.cmd.edit(dir .. "/beta.txt")
    assert.are.same({ { 15, 15 } }, rows(vim.api.nvim_get_current_buf()))
  end)

  it("clears every buffer when the review is gone", function()
    found = full_answer()
    on_answer()
    found = { pr = found.pr }
    on_answer()
    assert.are.same({}, rows(alpha))
    assert.are.same({}, rows(beta))
  end)

  it("drops the mark of a deleted review comment", function()
    found = full_answer()
    on_answer()
    table.remove(found.review.comments, 2)
    on_answer()
    assert.are.same({ { 7, 9 }, { 9, 30 }, { 30, 30 } }, rows(alpha))
  end)

  it("clears on a branch with no PR, and redraws back on the PR", function()
    found = full_answer()
    on_answer()
    tree = { root = dir, branch = "c" }
    on_tree("pr")
    assert.are.same({}, rows(alpha))
    tree = { root = dir, branch = "d", pr = 2 }
    on_tree("pr")
    assert.are.same({}, rows(alpha))
    tree = { root = dir, branch = "b", pr = 1 }
    on_tree("pr")
    assert.are.same({ { 15, 15 } }, rows(beta))
  end)

  it("skips a review comment past the buffer's last line", function()
    found = full_answer()
    table.insert(found.review.comments, comment("beta.txt", 99))
    on_answer()
    assert.are.same({ { 15, 15 } }, rows(beta))
  end)

  it("leaves buffers outside the root and unnamed buffers unmarked", function()
    other = vim.fn.tempname()
    vim.fn.mkdir(other, "p")
    vim.fn.writefile(lines(20, "beta"), other .. "/beta.txt")
    vim.cmd.edit(other .. "/beta.txt")
    local outside = vim.api.nvim_get_current_buf()
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, lines(20, "beta"))
    found = full_answer()
    on_answer()
    assert.are.same({}, rows(outside))
    assert.are.same({}, rows(scratch))
  end)

  it("colours the range's numbers and ends the line with the body", function()
    found = full_answer()
    on_answer()
    local details = assert(marks(beta)[1][4])
    assert.are.equal(render.REVIEW_COMMENT_HL, details.number_hl_group)
    assert.are.same({ { "● ", render.REVIEW_COMMENT_HL }, { "b", render.REVIEW_COMMENT_BODY_HL } }, details.virt_text)
  end)

  it("puts a bubble in the sign column on each review comment's first line", function()
    found = full_answer()
    on_answer()
    local bubble, hl = "󰍩 ", render.REVIEW_COMMENT_HL
    assert.are.same({ { 7, bubble, hl }, { 9, bubble, hl }, { 12, bubble, hl }, { 30, bubble, hl } }, signs(alpha))
    assert.are.same({ { 15, bubble, hl } }, signs(beta))
  end)

  it("puts a hollow bubble on a draft's first line", function()
    found = { pr = PR }
    drafts.keep(PR, { path = "beta.txt", line = 6, start_line = 5, head = "h", body = "d" })
    assert.are.same({ { 4, "󰍪 ", render.REVIEW_DRAFT_HL } }, signs(beta))
  end)

  it("gives a line one bubble, a review comment's over a draft's", function()
    found = full_answer()
    found.pr = PR
    drafts.keep(PR, { path = "beta.txt", line = 16, head = "h", body = "d" })
    assert.are.same({ { 15, "󰍩 ", render.REVIEW_COMMENT_HL } }, signs(beta))
  end)

  it("draws the bubble over gitsigns' and diagnostics' signs on its line", function()
    vim.wo.signcolumn = "yes"
    -- 6 is gitsigns' default sign_priority.
    vim.api.nvim_buf_set_extmark(beta, vim.api.nvim_create_namespace("spec.gitsigns"), 15, 0, {
      sign_text = "▎",
      priority = 6,
    })
    vim.diagnostic.set(vim.api.nvim_create_namespace("spec.diagnostics"), beta, {
      { lnum = 15, col = 0, severity = vim.diagnostic.severity.ERROR, message = "x" },
    })
    found = full_answer()
    on_answer()
    assert.are.equal("󰍩 ", vim.api.nvim_eval_statusline("%s", { use_statuscol_lnum = 16 }).str)
  end)

  it("keeps the bubble out of the sign column when review_comment.sign is false", function()
    config.setup({ review_comment = { sign = false } })
    found = full_answer()
    on_answer()
    assert.are.same({}, sign_texts(beta))
  end)

  it("answers a review comment's bubble and group on its first line only", function()
    found = full_answer()
    on_answer()
    assert.are.same({ "󰍩", render.REVIEW_COMMENT_HL }, { review_comments.bubble(alpha, 8) })
    assert.are.same({}, { review_comments.bubble(alpha, 9) })
  end)

  it("answers a draft's outline bubble", function()
    found = { pr = PR }
    drafts.keep(PR, { path = "beta.txt", line = 6, start_line = 5, head = "h", body = "d" })
    assert.are.same({ "󰍪", render.REVIEW_DRAFT_HL }, { review_comments.bubble(beta, 5) })
  end)

  it("answers the review comment's bubble on a line it shares with a draft", function()
    found = full_answer()
    found.pr = PR
    drafts.keep(PR, { path = "beta.txt", line = 16, head = "h", body = "d" })
    assert.are.same({ "󰍩", render.REVIEW_COMMENT_HL }, { review_comments.bubble(beta, 16) })
  end)

  it("answers each line's bubble when review_comment.sign is false", function()
    config.setup({ review_comment = { sign = false } })
    found = full_answer()
    found.pr = PR
    drafts.keep(PR, { path = "beta.txt", line = 6, head = "h", body = "d" })
    assert.are.same({ "󰍩", render.REVIEW_COMMENT_HL }, { review_comments.bubble(beta, 16) })
    assert.are.same({ "󰍪", render.REVIEW_DRAFT_HL }, { review_comments.bubble(beta, 6) })
  end)

  it("answers a line's bubble after text is typed at its start", function()
    found = full_answer()
    on_answer()
    vim.api.nvim_buf_set_text(beta, 15, 0, 15, 0, { "typed " })
    assert.are.same({ "󰍩", render.REVIEW_COMMENT_HL }, { review_comments.bubble(beta, 16) })
  end)

  it("clears its bubbles with its marks", function()
    found = full_answer()
    on_answer()
    found = { pr = found.pr }
    on_answer()
    assert.are.same({}, signs(beta))
  end)

  it("ends the line with only the first line of a CRLF body", function()
    found = full_answer()
    found.review.comments[5].body = "first\r\nsecond"
    on_answer()
    assert.are.equal("first", marks(beta)[1][4].virt_text[2][1])
  end)

  it("marks a file the sidebar loads from a CursorMoved callback", function()
    found = full_answer()
    on_answer()
    vim.cmd("%bwipeout!")
    local buf
    vim.api.nvim_create_autocmd("CursorMoved", {
      once = true,
      callback = function()
        buf = require("changeset.buffers").load(dir .. "/beta.txt")
      end,
    })
    vim.api.nvim_exec_autocmds("CursorMoved", {})
    assert.are.same({ { 15, 15 } }, rows(assert(buf)))
  end)
end)
