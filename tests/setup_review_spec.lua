local changeset = require("changeset")

---Autocmds PR Review Mode has registered.
local function review_autocmds()
  return vim.tbl_filter(function(autocmd)
    return autocmd.group_name == "changeset.review"
  end, vim.api.nvim_get_autocmds({ event = "User", pattern = "GitSignsUpdate" }))
end

-- The cases run in order: once activated, review's mode stays for the session.
describe("changeset.setup", function()
  it("registers nothing from review while pr_review.enabled is false", function()
    changeset.setup()
    changeset.setup({ pr_review = { enabled = false } })
    assert.equal(0, #review_autocmds())
    assert.is_nil(package.loaded["changeset.review"])
  end)

  it("activates review's mode once enabled, and keeps it until a restart", function()
    changeset.setup({ pr_review = { enabled = true } })
    changeset.setup({ pr_review = { enabled = true } })
    assert.equal(1, #review_autocmds())
    changeset.setup({})
    assert.equal(1, #review_autocmds())
  end)
end)
