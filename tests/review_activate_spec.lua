describe("changeset.review", function()
  it("creates no autocmd until activated", function()
    local before = #vim.api.nvim_get_autocmds({})

    require("changeset.review")

    assert.equal(before, #vim.api.nvim_get_autocmds({}))
  end)
end)
