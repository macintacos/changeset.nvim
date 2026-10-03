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
  pr = {
    start = function()
      require("changeset.pr").start()
    end,
    abandon = function()
      require("changeset.pr").abandon()
    end,
    comment = function(opts)
      require("changeset.pr").comment(opts.line1, opts.line2)
    end,
    delete = function()
      require("changeset.pr").delete()
    end,
    submit = function()
      require("changeset.pr").submit()
    end,
  },
}

---What `words` name in `subcommands`: a handler, a table of verbs, or nil.
---@param words string[]
---@return function|table|nil
local function lookup(words)
  local node = subcommands ---@type function|table|nil
  for _, word in ipairs(words) do
    if type(node) ~= "table" then
      return nil
    end
    node = node[word]
  end
  return node
end

---The sorted names in a table of subcommands or verbs.
---@param node table
---@return string[]
local function names(node)
  local keys = vim.tbl_keys(node)
  table.sort(keys)
  return keys
end

vim.api.nvim_create_user_command("Changeset", function(opts)
  local words = vim.split(opts.args, "%s+", { trimempty = true })
  local run = lookup(#words == 0 and { "toggle" } or words)
  if type(run) == "table" then
    return vim.notify(
      ("Changeset: :Changeset %s takes a verb: %s"):format(opts.args, table.concat(names(run), ", ")),
      vim.log.levels.ERROR
    )
  end
  if not run then
    return vim.notify("Changeset: unknown subcommand " .. opts.args, vim.log.levels.ERROR)
  end
  run(opts)
end, {
  nargs = "?",
  range = true,
  bar = true,
  desc = "Toggle the changeset sidebar, rebuild it, toggle PR Review Mode, start, submit or abandon the PR's pending review, add a review comment to it or reopen a draft, or delete either",
  complete = function(lead, line)
    -- Parses the last `|` segment so a modifier or earlier command still completes; an unset mark in a range makes it raise.
    local ok, cmd = pcall(vim.api.nvim_parse_cmd, line:match("[^|]*$"), {})
    if not ok then
      return {}
    end
    local words = vim.split(cmd.args[1] or "", "%s+", { trimempty = true })
    if lead ~= "" then
      table.remove(words)
    end
    local node = lookup(words)
    if type(node) ~= "table" then
      return {}
    end
    return vim.tbl_filter(function(name)
      return vim.startswith(name, lead)
    end, names(node))
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
