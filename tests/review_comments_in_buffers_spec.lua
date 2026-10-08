local changeset = require("changeset")
local comment_store = require("changeset.comment_store")
local Fixture = require("support.git")
local Paths = require("changeset.paths")

describe("review comments in buffers", function()
  local tmp, previous_dir

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
    assert.are.same({ "● ", "ChangesetReviewComment" }, details[1].virt_text[1])
    assert.are.same({ "one", "ChangesetReviewCommentBody" }, details[1].virt_text[2])
    assert.are.equal("ChangesetReviewComment", details[1].number_hl_group)
  end)

  it("tells a statuscolumn the bubble that the sign column leaves out", function()
    changeset.setup({ review_comment = { sign = false } })

    assert.are.same({ "󰍩", "ChangesetReviewComment" }, { changeset.bubble(keep_on_alpha(), 5) })
  end)
end)
