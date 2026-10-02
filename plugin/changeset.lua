---Entry points: `:Changeset`, `<Plug>(changeset-toggle)`, session restore and the mini.pick registry.
---Loads `changeset` only when it is used — not at load, nor for a session without a sidebar: its module-level
---autocmds start the tracker and watchers.

if vim.g.loaded_changeset then
  return
end
vim.g.loaded_changeset = true

local subcommands = {
  toggle = function()
    require("changeset").toggle()
  end,
  refresh = function()
    require("changeset.build").refresh()
  end,
  review = function()
    if not require("changeset.config").get().pr_review.enabled then
      return vim.notify("Changeset: :Changeset review needs pr_review.enabled = true in setup()", vim.log.levels.ERROR)
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
  bar = true,
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

local group = vim.api.nvim_create_augroup("changeset.plugin", {})

-- Fires: after a session is restored, which brings the sidebar's window back
-- without its contents. Refills it rather than leaving an empty window behind.
vim.api.nvim_create_autocmd("SessionLoadPost", {
  group = group,
  callback = function()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      -- Keep in sync with NAME in lua/changeset/window.lua.
      if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)):find("changeset://", 1, true) then
        return require("changeset").restore()
      end
    end
  end,
})

local function register_picker()
  if MiniPick then
    MiniPick.registry.changeset = function()
      return require("changeset.pick").pick()
    end
  end
end

if vim.v.vim_did_enter == 1 then
  register_picker()
else
  -- Fires: once startup is done, so a mini.pick set up anywhere in the user's config is seen.
  vim.api.nvim_create_autocmd("VimEnter", { group = group, once = true, callback = register_picker })
end
