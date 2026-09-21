-- Local plugin (no upstream repo)
-- <leader>gp opens a read-only sidebar mapping what this branch changed, nested
-- by the symbols each hunk touched. Sibling to <leader>gP (PR Review Mode),
-- which puts the same range in the gutter.

require("plugins.changeset").setup({
  -- Put the gutter in PR Review Mode whenever the sidebar opens. One-way: a
  -- close leaves the signs up, and `:PRReview` is what takes them down.
  gitsigns_base = true,
})

-- Mapped here rather than in plugin/which-key.lua so it travels with the plugin.
-- A plain keymap with a `desc` is all which-key needs to label it; `add()` is for
-- groups and description-only entries, and the <leader>g group already exists.
vim.keymap.set("n", "<leader>gp", function()
  require("plugins.changeset").toggle()
end, { desc = "Changeset (changed files & symbols)" })

-- Fires: after a session is restored, which brings the sidebar's window back
-- without its contents. Refills it rather than leaving an empty window behind.
vim.api.nvim_create_autocmd("SessionLoadPost", {
  callback = function()
    require("plugins.changeset").restore()
  end,
})
