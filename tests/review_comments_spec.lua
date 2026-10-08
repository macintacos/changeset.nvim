local Fixture = require("support.git")
local Notify = require("support.notify")
local comment_store = require("changeset.comment_store")
local review_comments = require("changeset.review_comments")
local config = require("changeset.config")
local render = require("changeset.render")

---@param path string
---@param line integer
---@param start_line integer?
local function comment(path, line, start_line)
  return { path = path, line = line, start_line = start_line, body = "b" }
end

local function all()
  return {
    comment("alpha.txt", 31),
    comment("alpha.txt", 13),
    comment("alpha.txt", 10, 8),
    comment("alpha.txt", 31, 10),
    comment("beta.txt", 16),
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

  ---Replaces the repository's review comments with `comments`.
  ---@param comments changeset.ReviewComment[]
  local function set(comments)
    comment_store.drop_all(dir)
    for _, c in ipairs(comments) do
      comment_store.keep(dir, c)
    end
  end

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
    vim.cmd.edit(dir .. "/beta.txt")
    beta = vim.api.nvim_get_current_buf()
  end)

  after_each(function()
    config.setup()
    vim.cmd("silent! %bwipeout!")
    os.remove(comment_store.path())
    vim.fn.delete(dir, "rf")
    if other then
      vim.fn.delete(other, "rf")
      other = nil
    end
  end)

  it("marks open buffers once a comment is kept", function()
    set(all())
    assert.are.same({ { 7, 9 }, { 9, 30 }, { 12, 12 }, { 30, 30 } }, rows(alpha))
    assert.are.same({ { 15, 15 } }, rows(beta))
  end)

  it("marks a buffer opened after its comments were kept", function()
    set(all())
    vim.cmd("%bwipeout!")
    vim.cmd.edit(dir .. "/beta.txt")
    assert.are.same({ { 15, 15 } }, rows(vim.api.nvim_get_current_buf()))
  end)

  it("clears every buffer when the review is abandoned", function()
    set(all())
    comment_store.drop_all(dir)
    assert.are.same({}, rows(alpha))
    assert.are.same({}, rows(beta))
  end)

  it("drops the mark of a deleted review comment", function()
    set(all())
    comment_store.drop(dir, comment("alpha.txt", 13))
    assert.are.same({ { 7, 9 }, { 9, 30 }, { 30, 30 } }, rows(alpha))
  end)

  it("marks no line for a review comment on the whole file", function()
    set({ comment("beta.txt", 16), { path = "beta.txt", body = "b" } })
    assert.are.same({ { 15, 15 } }, rows(beta))
  end)

  it("skips a review comment past the buffer's last line", function()
    set(vim.list_extend(all(), { comment("beta.txt", 99) }))
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
    set(all())
    assert.are.same({}, rows(outside))
    assert.are.same({}, rows(scratch))
  end)

  it("colours the range's numbers and ends the line with the body", function()
    set(all())
    local details = assert(marks(beta)[1][4])
    assert.are.equal(render.REVIEW_COMMENT_HL, details.number_hl_group)
    assert.are.same({ { "● ", render.REVIEW_COMMENT_HL }, { "b", render.REVIEW_COMMENT_BODY_HL } }, details.virt_text)
  end)

  it("marks a draft with its own circle, sign and group", function()
    set({ { path = "beta.txt", line = 15, body = "b", draft = true } })
    local details = assert(marks(beta)[1][4])
    assert.are.equal(render.REVIEW_COMMENT_DRAFT_HL, details.number_hl_group)
    assert.are.same({ "◌ ", render.REVIEW_COMMENT_DRAFT_HL }, details.virt_text[1])
    assert.are.same({ { 14, "󰍪 ", render.REVIEW_COMMENT_DRAFT_HL } }, signs(beta))
    assert.are.same({ "󰍪", render.REVIEW_COMMENT_DRAFT_HL }, { review_comments.bubble(beta, 15) })
  end)

  for _, order in ipairs({ "draft first", "draft last" }) do
    it(
      ("gives a line where a draft and a saved comment start the draft's bubble, %s in the store"):format(order),
      function()
        local draft = { path = "beta.txt", line = 15, body = "d", draft = true }
        local saved = { path = "beta.txt", line = 16, start_line = 15, body = "s" }
        set(order == "draft first" and { draft, saved } or { saved, draft })
        assert.are.same({ { 14, "󰍪 ", render.REVIEW_COMMENT_DRAFT_HL } }, signs(beta))
        assert.are.same({ "󰍪", render.REVIEW_COMMENT_DRAFT_HL }, { review_comments.bubble(beta, 15) })
      end
    )
  end

  it("puts a bubble in the sign column on each review comment's first line", function()
    set(all())
    local bubble, hl = "󰍩 ", render.REVIEW_COMMENT_HL
    assert.are.same({ { 7, bubble, hl }, { 9, bubble, hl }, { 12, bubble, hl }, { 30, bubble, hl } }, signs(alpha))
    assert.are.same({ { 15, bubble, hl } }, signs(beta))
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
    set(all())
    assert.are.equal("󰍩 ", vim.api.nvim_eval_statusline("%s", { use_statuscol_lnum = 16 }).str)
  end)

  it("keeps the bubble out of the sign column when review_comment.sign is false", function()
    config.setup({ review_comment = { sign = false } })
    set(all())
    assert.are.same({}, sign_texts(beta))
  end)

  it("answers a review comment's bubble and group on its first line only", function()
    set(all())
    assert.are.same({ "󰍩", render.REVIEW_COMMENT_HL }, { review_comments.bubble(alpha, 8) })
    assert.are.same({}, { review_comments.bubble(alpha, 9) })
  end)

  it("answers each line's bubble when review_comment.sign is false", function()
    config.setup({ review_comment = { sign = false } })
    set(all())
    assert.are.same({ "󰍩", render.REVIEW_COMMENT_HL }, { review_comments.bubble(beta, 16) })
  end)

  it("answers a line's bubble after text is typed at its start", function()
    set(all())
    vim.api.nvim_buf_set_text(beta, 15, 0, 15, 0, { "typed " })
    assert.are.same({ "󰍩", render.REVIEW_COMMENT_HL }, { review_comments.bubble(beta, 16) })
  end)

  it("clears its bubbles with its marks", function()
    set(all())
    comment_store.drop_all(dir)
    assert.are.same({}, signs(beta))
  end)

  it("ends the line with only the first line of a CRLF body", function()
    set({ { path = "beta.txt", line = 16, body = "first\r\nsecond" } })
    assert.are.equal("first", marks(beta)[1][4].virt_text[2][1])
  end)

  it("marks a file the sidebar loads from a CursorMoved callback", function()
    set(all())
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

  ---@param buf integer
  local function write(buf)
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent write")
    end)
  end

  it("stores the lines a written buffer's edits moved to, a draft's too, leaving a whole file's comment", function()
    local whole = { path = "beta.txt", body = "w" }
    set({ comment("beta.txt", 16), { path = "beta.txt", line = 5, body = "d", draft = true }, whole })
    vim.api.nvim_buf_set_lines(beta, 0, 0, false, { "new 1", "new 2" })

    write(beta)

    assert.are.same({
      { path = "beta.txt", line = 18, body = "b" },
      { path = "beta.txt", line = 7, body = "d", draft = true },
      whole,
    }, comment_store.list(dir))
    assert.are.same({ { 6, 6 }, { 17, 17 } }, rows(beta))
  end)

  for name, damage in pairs({
    unreadable = function(path)
      vim.fn.writefile({ "{" }, path)
    end,
    unwritable = function(path)
      vim.uv.fs_chmod(path, tonumber("444", 8))
      vim.uv.fs_chmod(vim.fs.dirname(path), tonumber("555", 8))
    end,
  }) do
    it(("moves a comment by the edits of a write its %s record refused, on the next write"):format(name), function()
      set({ comment("beta.txt", 10) })
      local path = comment_store.path()
      local saved = vim.fn.readfile(path)
      vim.api.nvim_buf_set_lines(beta, 0, 0, false, { "new 1", "new 2" })
      damage(path)

      write(beta)

      vim.uv.fs_chmod(vim.fs.dirname(path), tonumber("755", 8))
      vim.uv.fs_chmod(path, tonumber("644", 8))
      vim.fn.writefile(saved, path)
      vim.api.nvim_buf_set_lines(beta, 0, 0, false, { "new 0" })
      write(beta)

      assert.are.same({ comment("beta.txt", 13) }, comment_store.list(dir))
    end)
  end

  it("moves a comment by the edits of a write its record refused, through a redraw before the next write", function()
    set({ comment("beta.txt", 10) })
    local path = comment_store.path()
    local saved = vim.fn.readfile(path)
    vim.api.nvim_buf_set_lines(beta, 0, 0, false, { "new 1", "new 2" })
    vim.fn.writefile({ "{" }, path)
    write(beta)

    review_comments.redraw()
    vim.fn.writefile(saved, path)
    review_comments.redraw()
    vim.api.nvim_buf_set_lines(beta, 0, 0, false, { "new 0" })
    write(beta)

    assert.are.same({ comment("beta.txt", 13) }, comment_store.list(dir))
  end)

  it("stores the lines a written buffer's edits moved its submitted comments to, with none listed there", function()
    set({ comment("beta.txt", 16) })
    comment_store.take(dir, { comments = { comment("beta.txt", 16) }, at = 0, to = "claude" })
    vim.api.nvim_buf_set_lines(beta, 0, 0, false, { "new 1", "new 2" })

    write(beta)

    assert.are.same({ comment("beta.txt", 18) }, assert(comment_store.submitted(dir))[1].comments)
  end)

  ---An LSP edit replacing rows `first` to `last`, end exclusive, with `new`.
  ---@param first integer
  ---@param last integer
  ---@param new string[]
  ---@return table
  local function text_edit(first, last, new)
    local text = #new > 0 and table.concat(new, "\n") .. "\n" or ""
    return {
      range = { start = { line = first, character = 0 }, ["end"] = { line = last, character = 0 } },
      newText = text,
    }
  end

  local indented = { "  alpha 4", "  alpha 5", "  alpha 6" }
  for _, case in ipairs({
    {
      "a formatter rewriting the block that holds them",
      function()
        vim.lsp.util.apply_text_edits({ text_edit(3, 6, indented) }, alpha, "utf-16")
      end,
      0,
    },
    {
      "a formatter rewriting their block and adding a line above",
      function()
        vim.lsp.util.apply_text_edits({ text_edit(1, 1, { "added" }), text_edit(3, 6, indented) }, alpha, "utf-16")
      end,
      1,
    },
    {
      "a filter of the whole buffer",
      function()
        vim.api.nvim_buf_call(alpha, function()
          vim.cmd("silent %!cat")
        end)
      end,
      0,
    },
    {
      "the whole buffer set again to the same text",
      function()
        vim.api.nvim_buf_set_lines(alpha, 0, -1, false, vim.api.nvim_buf_get_lines(alpha, 0, -1, false))
      end,
      0,
    },
    {
      "a language server's edit of the whole document",
      function()
        local document = vim.api.nvim_buf_get_lines(alpha, 0, -1, false)
        document[4], document[5], document[6] = unpack(indented)
        vim.lsp.util.apply_text_edits({ text_edit(0, #document, document) }, alpha, "utf-16")
      end,
      0,
    },
  }) do
    local name, edit, shift = case[1], case[2], case[3]
    it(("keeps each comment on its own line through %s"):format(name), function()
      set({
        { path = "alpha.txt", line = 3, start_line = 2, body = "r" },
        { path = "alpha.txt", line = 4, body = "a" },
        { path = "alpha.txt", line = 5, body = "b" },
        { path = "alpha.txt", line = 6, body = "c" },
      })
      edit()

      write(alpha)

      assert.are.same({
        { path = "alpha.txt", line = 3 + shift, start_line = 2 + shift, body = "r" },
        { path = "alpha.txt", line = 4 + shift, body = "a" },
        { path = "alpha.txt", line = 5 + shift, body = "b" },
        { path = "alpha.txt", line = 6 + shift, body = "c" },
      }, comment_store.list(dir))
    end)
  end

  it("merges comments an edit brings onto the same lines, a draft when either was", function()
    set({
      { path = "alpha.txt", line = 13, body = "gone" },
      { path = "alpha.txt", line = 14, body = "kept", draft = true },
    })
    vim.api.nvim_buf_set_lines(alpha, 12, 13, false, {})

    write(alpha)

    assert.are.same({ { path = "alpha.txt", line = 13, body = "gone\n\nkept", draft = true } }, comment_store.list(dir))
  end)

  it("warns where a write merged comments, and that the result is a draft", function()
    set({
      { path = "alpha.txt", line = 13, body = "gone" },
      { path = "alpha.txt", line = 14, body = "kept", draft = true },
    })
    vim.api.nvim_buf_set_lines(alpha, 12, 13, false, {})
    local notes, restore = Notify.capture()

    local ok, err = pcall(write, alpha)

    restore()
    assert(ok, err)
    local warnings = Notify.messages(notes, vim.log.levels.WARN)
    assert.are.equal(1, #warnings)
    assert.truthy(warnings[1]:find("line 13 of alpha.txt", 1, true))
    assert.truthy(warnings[1]:find("draft", 1, true))
  end)

  it("keeps a modified buffer's marks where its edits moved them when another file's comment is kept", function()
    set({ comment("beta.txt", 16) })
    vim.api.nvim_buf_set_lines(beta, 0, 0, false, { "new 1", "new 2" })

    comment_store.keep(dir, comment("alpha.txt", 3))

    assert.are.same({ { 17, 17 } }, rows(beta))
  end)

  it("leaves the stored lines alone when the buffer is written to another file", function()
    set({ comment("beta.txt", 16) })
    vim.api.nvim_buf_set_lines(beta, 0, 0, false, { "new 1", "new 2" })

    vim.api.nvim_buf_call(beta, function()
      vim.cmd("silent write " .. vim.fn.fnameescape(dir .. "/copy.txt"))
    end)

    assert.are.same({ comment("beta.txt", 16) }, comment_store.list(dir))
    assert.are.same({ { 17, 17 } }, rows(beta))
  end)

  it("defines its groups again after a colorscheme change", function()
    vim.cmd("colorscheme default")

    assert.is_true(vim.api.nvim_get_hl(0, { name = render.REVIEW_COMMENT_HL }).bold)
  end)
end)
