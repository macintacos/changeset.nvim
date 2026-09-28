---Entry points: `:Changeset`, `<Plug>(changeset-toggle)`, session restore and the mini.pick registry.
---Requires nothing from `changeset` at load: its module-level autocmds start the tracker and watchers.

if vim.g.loaded_changeset then
  return
end
vim.g.loaded_changeset = true

local subcommands = {
  toggle = function()
    require("changeset").toggle()
  end,
  refresh = function()
    require("changeset").refresh()
  end,
  review = function()
    if not require("changeset.config").get().pr_review.enabled then
      return vim.notify("Changeset: PR Review Mode is off; set pr_review.enabled in setup()", vim.log.levels.ERROR)
    end
    require("changeset.review").toggle()
  end,
}

vim.api.nvim_create_user_command("Changeset", function(opts)
  local run = subcommands[opts.args == "" and "toggle" or opts.args]
  if not run then
    return vim.notify("Changeset: unknown subcommand " .. opts.args, vim.log.levels.ERROR)
  end
  run()
end, {
  nargs = "?",
  desc = "Toggle the changeset sidebar, rebuild it, or toggle PR Review Mode",
  complete = function(lead)
    local names = vim.tbl_filter(function(name)
      return vim.startswith(name, lead)
    end, vim.tbl_keys(subcommands))
    table.sort(names)
    return names
  end,
})

vim.keymap.set("n", "<Plug>(changeset-toggle)", subcommands.toggle, { desc = "Toggle the changeset sidebar" })

-- Fires: after a session is restored, which brings the sidebar's window back
-- without its contents. Refills it rather than leaving an empty window behind.
vim.api.nvim_create_autocmd("SessionLoadPost", {
  callback = function()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      -- Keep in sync with NAME in lua/changeset/window.lua.
      if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)):find("changeset://", 1, true) then
        return require("changeset").restore()
      end
    end
  end,
})

-- Fires: once startup is done, so a mini.pick set up anywhere in the user's config is seen.
vim.api.nvim_create_autocmd("VimEnter", {
  callback = function()
    if MiniPick then
      MiniPick.registry.changeset = function()
        return require("changeset.pick").pick()
      end
    end
  end,
})
