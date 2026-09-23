-- Local plugin (no upstream repo)
-- <leader>gp opens a read-only sidebar mapping what this branch changed, nested
-- by the symbols each hunk touched. Sibling to <leader>gP (PR Review Mode),
-- which marks the branch's changes in the gutter.

-- Mapped here rather than in plugin/which-key.lua so it travels with the plugin.
-- A plain keymap with a `desc` is all which-key needs to label it; `add()` is for
-- groups and description-only entries, and the <leader>g group already exists.
vim.keymap.set("n", "<leader>gp", function()
  require("plugins.changeset").toggle()
end, { desc = "Changeset (changed files & symbols)" })

-- Fires: once, at startup. Builds the tree just after startup so the first
-- <leader>gp opens onto it. Scheduled so it runs after the first paint and after
-- plugin/mini/sessions.lua has restored a session inside its own VimEnter —
-- the tree then follows the restored buffer, not the bare one. Skipped without a
-- UI and on git's own editor buffers (a commit message, a rebase todo): building
-- loads every changed file and starts its language server, which nobody there
-- will open the sidebar to see.
vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    vim.schedule(function()
      local ft = vim.bo.filetype
      if #vim.api.nvim_list_uis() == 0 or ft == "gitcommit" or ft == "gitrebase" or vim.bo.buftype ~= "" then
        return
      end
      require("plugins.changeset").build()
    end)
  end,
})

-- Fires: after a session is restored, which brings the sidebar's window back
-- without its contents. Refills it rather than leaving an empty window behind.
vim.api.nvim_create_autocmd("SessionLoadPost", {
  callback = function()
    require("plugins.changeset").restore()
  end,
})
