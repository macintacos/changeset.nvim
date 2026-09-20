-- Local plugin (no upstream repo)
-- <leader>gP opens a read-only sidebar mapping what this branch changed, nested
-- by the symbols each hunk touched. Sibling to <leader>gp (PR Review Mode),
-- which puts the same range in the gutter.

-- Mapped here rather than in plugin/which-key.lua so it travels with the plugin.
-- A plain keymap with a `desc` is all which-key needs to label it; `add()` is for
-- groups and description-only entries, and the <leader>g group already exists.
vim.keymap.set("n", "<leader>gP", function()
  require("plugins.prtree").toggle()
end, { desc = "PR Review Tree (changed files & symbols)" })
