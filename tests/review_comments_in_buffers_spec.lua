local changeset = require("changeset")
local comment_store = require("changeset.comment_store")
local Fixture = require("support.git")
local Paths = require("changeset.paths")
local present = require("support.present")
local review_comments = require("changeset.review_comments")

describe("review comments in buffers", function()
  local tmp ---@type string
  local previous_dir ---@type string

  before_each(function()
    tmp, previous_dir = Fixture.enter_tempdir()
    Fixture.init_repo("trunk", tmp)
    vim.fn.writefile(Fixture.numbered(40, nil, "alpha"), "alpha.txt")
    Fixture.commit("alpha", tmp)
    os.remove(comment_store.path())
  end)

  after_each(function()
    changeset.setup()
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
    os.remove(comment_store.path())
  end)

  ---@param buf integer
  ---@return vim.api.keyset.extmark_details[]
  local function mark_details(buf)
    local ns = vim.api.nvim_get_namespaces()["changeset.review_comments"]
    return vim.tbl_map(function(mark)
      return mark[4]
    end, vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }))
  end

  ---Opens alpha.txt, with no sidebar, and keeps a comment on its lines 5-6.
  ---@return integer alpha
  local function keep_on_alpha()
    vim.cmd.edit("alpha.txt")
    local alpha = vim.api.nvim_get_current_buf()
    comment_store.keep(Paths.root(alpha), { path = "alpha.txt", line = 6, start_line = 5, body = "one\nmore" })
    return alpha
  end

  it("marks a kept comment in its file with no sidebar open", function()
    local details = mark_details(keep_on_alpha())

    assert.are.equal(1, #details)
    local detail = present(details[1])
    local virt_text = present(detail.virt_text)
    assert.are.same({ "● ", "ChangesetReviewComment" }, virt_text[1])
    assert.are.same({ "one", "ChangesetReviewCommentBody" }, virt_text[2])
    assert.are.equal("ChangesetReviewComment", detail.number_hl_group)
  end)

  it("tells a statuscolumn the bubble that the sign column leaves out", function()
    changeset.setup({ review_comment = { sign = false } })

    assert.are.same({ "󰍩", "ChangesetReviewComment" }, { changeset.bubble(keep_on_alpha(), 5) })
  end)

  describe("with more of the repository's files loaded", function()
    local others

    before_each(function()
      others = {}
      for i = 1, 4 do
        local path = tmp .. "/other" .. i .. ".txt"
        vim.fn.writefile({ "x" }, path)
        others[i] = vim.fn.bufadd(path)
        vim.fn.bufload(others[i])
      end
    end)

    ---How often `comment_store.branch` runs while `fn` does.
    ---@param fn fun()
    ---@return integer
    local function branch_reads(fn)
      local real, reads = comment_store.branch, 0
      comment_store.branch = function(...)
        reads = reads + 1
        return real(...)
      end
      local ok, err = pcall(fn)
      comment_store.branch = real
      assert.is_true(ok, tostring(err))
      return reads
    end

    it("reads the repository's branch once when it redraws every buffer", function()
      keep_on_alpha()

      assert.are.equal(
        1,
        branch_reads(function()
          require("changeset.review_comments").redraw()
        end)
      )
    end)

    it("reads the repository's branch once as focus comes back", function()
      keep_on_alpha()

      assert.are.equal(
        1,
        branch_reads(function()
          vim.api.nvim_exec_autocmds("FocusGained", {})
        end)
      )
    end)

    it("leaves the blocks of a buffer with no review comments alone as it redraws", function()
      local alpha = keep_on_alpha()
      local blocks = require("changeset.review_comment_blocks")
      local real, drawn = blocks.draw, {}
      blocks.draw = function(buf, ...)
        drawn[buf] = true
        return real(buf, ...)
      end

      local ok, err = pcall(require("changeset.review_comments").redraw)
      blocks.draw = real

      assert.is_true(ok, tostring(err))
      assert.are.same({ [alpha] = true }, drawn)
    end)
  end)

  it("keeps a file's mark through a redraw beside a buffer with 'buftype' set, the cwd elsewhere", function()
    local root = vim.fn.resolve(tmp)
    local cache = vim.fn.stdpath("cache") --[[@as string]]
    vim.fn.mkdir(cache, "p")
    vim.fn.chdir(cache)
    -- Keeps the first buffer from being reused, so the special buffer is listed ahead of the file.
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "scratch" })
    -- As vim-gnupg leaves a decrypted file, or `:help` a repository's own doc file.
    local special = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(special, root .. "/secret.gpg")
    vim.bo[special].buftype = "acwrite"
    vim.cmd.edit(root .. "/alpha.txt")
    local alpha = vim.api.nvim_get_current_buf()
    comment_store.keep(root, { path = "alpha.txt", line = 3, body = "note" })

    review_comments.redraw()

    assert.are.equal(1, #mark_details(alpha))
  end)
end)
