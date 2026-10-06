---Entry points: `:Changeset`, its `<Plug>` maps and default `<C-g>` keys, session restore and the mini.pick registry.
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
  comment = function(opts)
    require("changeset.reviewing").comment(opts.line1, opts.line2)
  end,
  delete = function()
    require("changeset.reviewing").delete()
  end,
  abandon = function()
    require("changeset.reviewing").abandon()
  end,
  submit = function()
    require("changeset.reviewing").submit()
  end,
  next = function()
    require("changeset.reviewing").next()
  end,
  prev = function()
    require("changeset.reviewing").prev()
  end,
  list = function()
    require("changeset.reviewing").list()
  end,
  yank = function()
    require("changeset.reviewing").yank()
  end,
}

vim.api.nvim_create_user_command("Changeset", function(opts)
  local run = subcommands[opts.args == "" and "toggle" or opts.args]
  if not run then
    return vim.notify("Changeset: unknown subcommand " .. opts.args, vim.log.levels.ERROR)
  end
  run(opts)
end, {
  nargs = "?",
  range = true,
  bar = true,
  desc = "Toggle the changeset sidebar, rebuild it, toggle PR Review Mode, or write, delete, abandon or submit review comments",
  complete = function(lead)
    local names = vim.tbl_filter(function(name)
      return vim.startswith(name, lead)
    end, vim.tbl_keys(subcommands))
    table.sort(names)
    return names
  end,
})

---Each subcommand's default key under `<C-g>`, and what it does.
local keys = {
  { "c", "comment", "Comment on this line, or the selection, or edit the comment there", { "n", "x" } },
  { "d", "delete", "Delete the review comment on this line" },
  { "n", "next", "Next review comment" },
  { "p", "prev", "Previous review comment" },
  { "l", "list", "List the review comments in the quickfix list" },
  { "y", "yank", "Copy the review as text" },
  { "s", "submit", "Send the review to an agent" },
  { "a", "abandon", "Abandon the review" },
  { "t", "toggle", "Toggle the changeset sidebar" },
  { "r", "refresh", "Rebuild the changeset sidebar" },
  { "m", "review", "Toggle PR Review Mode" },
}

for _, key in ipairs(keys) do
  local name, desc = key[2], key[3]
  -- <Cmd>, not a function, so a map loads no changeset module until it's used.
  vim.keymap.set("n", ("<Plug>(changeset-%s)"):format(name), ("<Cmd>Changeset %s<CR>"):format(name), { desc = desc })
end
-- `:`, not <Cmd>, so the selection arrives as the '<,'> range.
vim.keymap.set("x", "<Plug>(changeset-comment)", ":Changeset comment<CR>", { silent = true, desc = keys[1][3] })

---Maps each default `<C-g>` key not already taken, unless `vim.g.changeset_no_default_maps` is set.
local function map_defaults()
  if vim.g.changeset_no_default_maps then
    return
  end
  for _, key in ipairs(keys) do
    local lhs = "<C-g>" .. key[1]
    for _, mode in ipairs(key[4] or { "n" }) do
      if vim.fn.maparg(lhs, mode) == "" then
        vim.keymap.set(mode, lhs, ("<Plug>(changeset-%s)"):format(key[2]), { desc = key[3] })
      end
    end
  end
end

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

local function after_startup()
  register_picker()
  map_defaults()
end

if vim.v.vim_did_enter == 1 then
  after_startup()
else
  -- Fires: once startup is done, so a mini.pick set up, a key mapped or the default keys turned off anywhere in the
  -- user's config is seen.
  vim.api.nvim_create_autocmd("VimEnter", { group = group, once = true, callback = after_startup })
end
