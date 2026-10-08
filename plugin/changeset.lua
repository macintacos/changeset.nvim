---Entry points: `:Changeset`, its `<Plug>` maps and default `<C-g>` keys, session restore and the mini.pick registry.
---Loads `changeset` only when it is used — not at load, nor for a session without a sidebar: its module-level
---autocmds start the tracker and watchers.

if vim.g.loaded_changeset then
  return
end
vim.g.loaded_changeset = true

---Each subcommand by its words, as typed after `:Changeset`.
local subcommands = {
  toggle = function()
    require("changeset").toggle()
  end,
  refresh = function()
    require("changeset").refresh()
  end,
  next = function()
    require("changeset").step(1)
  end,
  prev = function()
    require("changeset").step(-1)
  end,
  ["next symbol"] = function()
    require("changeset").step(1, "symbol")
  end,
  ["prev symbol"] = function()
    require("changeset").step(-1, "symbol")
  end,
  ["next file"] = function()
    require("changeset").step(1, "file")
  end,
  ["prev file"] = function()
    require("changeset").step(-1, "file")
  end,
  ["preview next"] = function()
    require("changeset").preview_step(1)
  end,
  ["preview prev"] = function()
    require("changeset").preview_step(-1)
  end,
  ["review mode"] = function()
    if not require("changeset.config").get().pr_review.enabled then
      return vim.notify(
        "Changeset: :Changeset review mode needs pr_review.enabled = true in setup()",
        vim.log.levels.ERROR
      )
    end
    require("changeset.review").toggle()
  end,
  ["review submit"] = function()
    require("changeset.reviewing").submit()
  end,
  ["review restore"] = function()
    require("changeset.reviewing").restore()
  end,
  ["review yank"] = function()
    require("changeset.reviewing").yank()
  end,
  ["review abandon"] = function()
    require("changeset.reviewing").abandon()
  end,
  ["comment new"] = function(opts)
    local reviewing = require("changeset.reviewing")
    if opts.range == 0 then
      return reviewing.comment_here()
    end
    reviewing.comment(opts.line1, opts.line2)
  end,
  ["comment del"] = function()
    require("changeset.reviewing").delete()
  end,
  ["comment draft"] = function()
    require("changeset.reviewing").draft()
  end,
  ["comment next"] = function()
    require("changeset.reviewing").next_comment(1)
  end,
  ["comment prev"] = function()
    require("changeset.reviewing").prev_comment(1)
  end,
  ["comment last"] = function()
    require("changeset.reviewing").last_comment()
  end,
  ["comment list"] = function()
    require("changeset.reviewing").list()
  end,
  ["comment toggle"] = function()
    require("changeset.review_comments").toggle()
  end,
}

---The review comment window, when it is current. Never loads its module: no window is open until it is loaded.
---@return changeset.ReviewCommentWindow?
local function comment_window()
  local module = package.loaded["changeset.review_comment_window"]
  return module and module.current()
end

---The word after `prefix` in each subcommand that starts with it, sorted.
---@param prefix string Whole words, each followed by a space: "" or "comment ".
---@return string[]
local function next_words(prefix)
  local words = {}
  for name in pairs(subcommands) do
    local word = vim.startswith(name, prefix) and name:sub(#prefix + 1):match("^%S+")
    if word then
      words[word] = true
    end
  end
  local names = vim.tbl_keys(words)
  table.sort(names)
  return names
end

---Why `fargs`, which name no subcommand, can't run.
---@param fargs string[]
---@return string
local function unknown(fargs)
  local verbs = next_words(fargs[1] .. " ")
  if #verbs == 0 and subcommands[fargs[1]] then
    return (":Changeset %s takes no arguments"):format(fargs[1])
  end
  if #verbs == 0 then
    return "unknown subcommand " .. table.concat(fargs, " ")
  end
  if #fargs == 1 then
    return (":Changeset %s takes a verb: %s"):format(fargs[1], table.concat(verbs, ", "))
  end
  local name = fargs[1] .. " " .. fargs[2]
  if subcommands[name] then
    return (":Changeset %s takes no arguments"):format(name)
  end
  return (":Changeset %s has no verb %s; its verbs: %s"):format(
    fargs[1],
    table.concat(fargs, " ", 2),
    table.concat(verbs, ", ")
  )
end

vim.api.nvim_create_user_command("Changeset", function(opts)
  local name = #opts.fargs == 0 and "toggle" or table.concat(opts.fargs, " ")
  local run = subcommands[name]
  if not run then
    return vim.notify("Changeset: " .. unknown(opts.fargs), vim.log.levels.ERROR)
  end
  local open = comment_window()
  if open then
    return require("changeset.reviewing").from_window(open, name, function()
      run(opts)
    end)
  end
  run(opts)
end, {
  nargs = "*",
  range = true,
  bar = true,
  desc = "Toggle the changeset sidebar, rebuild it, step through its changes, symbols or files, open or preview them, toggle PR Review Mode, submit, restore, copy or abandon the review, or write, delete, draft, walk, reopen, list or show review comments",
  complete = function(lead, line)
    -- The words between `Changeset`, with any range before it, and `lead`.
    local typed = vim.trim(line:match("^%S+%s+(.-)%S*$") or "")
    local prefix = typed == "" and "" or typed:gsub("%s+", " ") .. " "
    return vim.tbl_filter(function(word)
      return vim.startswith(word, lead)
    end, next_words(prefix))
  end,
})

---A subcommand's default key.
---@class changeset.DefaultKey
---@field lhs string
---@field name string The subcommand, as typed after `:Changeset`.
---@field desc string
---@field modes? string[] Default `{ "n" }`.
---@field icon { cat: string, name: string } Its which-key icon: a category and name which-key asks mini.icons for, so it is drawn from the user's icon set.
---@field operatorfunc? string For a step `.` repeats, its `'operatorfunc'` call, `%d` standing for the count.

---@type changeset.DefaultKey[]
local keys = {
  {
    lhs = "<C-g>cc",
    name = "comment new",
    desc = "Comment on this line, or the selection, or edit the comment there",
    modes = { "n", "x" },
    icon = { cat = "filetype", name = "messages" },
  },
  {
    lhs = "<C-g>cd",
    name = "comment del",
    desc = "Delete the review comment on this line",
    icon = { cat = "directory", name = "Trash" },
  },
  {
    lhs = "<C-g>ch",
    name = "comment draft",
    desc = "Hold the review comment on this line back as a draft, or save it",
    icon = { cat = "filetype", name = "messages" },
  },
  {
    lhs = "<C-g>cn",
    name = "comment next",
    desc = "Next review comment",
    icon = { cat = "filetype", name = "messages" },
    operatorfunc = "v:lua.require'changeset.reviewing'.next_comment(%d)",
  },
  {
    lhs = "<C-g>cp",
    name = "comment prev",
    desc = "Previous review comment",
    icon = { cat = "filetype", name = "messages" },
    operatorfunc = "v:lua.require'changeset.reviewing'.prev_comment(%d)",
  },
  {
    lhs = "<C-g>cl",
    name = "comment last",
    desc = "Edit the review comment you saved last",
    icon = { cat = "filetype", name = "messages" },
  },
  {
    lhs = "<C-g>cq",
    name = "comment list",
    desc = "List the review comments in the quickfix list",
    icon = { cat = "filetype", name = "qf" },
  },
  {
    lhs = "<C-g>ct",
    name = "comment toggle",
    desc = "Show or hide the review comments' whole text in blocks",
    icon = { cat = "filetype", name = "text" },
  },
  {
    lhs = "<C-g>nn",
    name = "next",
    desc = "Open the next change",
    icon = { cat = "filetype", name = "diff" },
    operatorfunc = "v:lua.require'changeset'.step(%d)",
  },
  {
    lhs = "<C-g>np",
    name = "prev",
    desc = "Open the previous change",
    icon = { cat = "filetype", name = "diff" },
    operatorfunc = "v:lua.require'changeset'.step(-%d)",
  },
  {
    lhs = "<C-g>ns",
    name = "next symbol",
    desc = "Open the next changed symbol",
    icon = { cat = "lsp", name = "Function" },
    operatorfunc = "v:lua.require'changeset'.step(%d, 'symbol')",
  },
  {
    lhs = "<C-g>nS",
    name = "prev symbol",
    desc = "Open the previous changed symbol",
    icon = { cat = "lsp", name = "Function" },
    operatorfunc = "v:lua.require'changeset'.step(-%d, 'symbol')",
  },
  {
    lhs = "<C-g>nf",
    name = "next file",
    desc = "Open the next changed file",
    icon = { cat = "default", name = "file" },
    operatorfunc = "v:lua.require'changeset'.step(%d, 'file')",
  },
  {
    lhs = "<C-g>nF",
    name = "prev file",
    desc = "Open the previous changed file",
    icon = { cat = "default", name = "file" },
    operatorfunc = "v:lua.require'changeset'.step(-%d, 'file')",
  },
  {
    lhs = "]g",
    name = "preview next",
    desc = "Preview the next change",
    icon = { cat = "filetype", name = "diff" },
  },
  {
    lhs = "[g",
    name = "preview prev",
    desc = "Preview the previous change",
    icon = { cat = "filetype", name = "diff" },
  },
  { lhs = "<C-g>y", name = "review yank", desc = "Copy the review as text", icon = { cat = "lsp", name = "Text" } },
  {
    lhs = "<C-g>s",
    name = "review submit",
    desc = "Submit the review to an agent",
    icon = { cat = "filetype", name = "robots" },
  },
  {
    lhs = "<C-g>a",
    name = "review abandon",
    desc = "Abandon the review",
    icon = { cat = "directory", name = "Trash" },
  },
  { lhs = "<C-g>g", name = "toggle", desc = "Toggle the changeset sidebar", icon = { cat = "filetype", name = "git" } },
  {
    lhs = "<C-g>r",
    name = "refresh",
    desc = "Rebuild the changeset sidebar",
    icon = { cat = "filetype", name = "git" },
  },
  {
    lhs = "<C-g>m",
    name = "review mode",
    desc = "Toggle PR Review Mode",
    icon = { cat = "directory", name = ".github" },
  },
}

local comment_new = assert(vim.iter(keys):find(function(key)
  return key.name == "comment new"
end))

---The `<Plug>` map of subcommand `name`, its words joined by hyphens.
---@param name string
---@return string
local function plug(name)
  return ("<Plug>(changeset-%s)"):format((name:gsub(" ", "-")))
end

for _, key in ipairs(keys) do
  local lhs = plug(key.name)
  if key.operatorfunc then
    -- A g@ operator is what `.` repeats. The count is baked into the lambda, and <Esc> drops the typed one, so `.`
    -- repeats the first count.
    vim.keymap.set("n", lhs, function()
      if comment_window() then
        return ("<Cmd>Changeset %s<CR>"):format(key.name)
      end
      vim.o.operatorfunc = ("{_ -> %s}"):format(key.operatorfunc:format(vim.v.count1))
      return "<Esc>g@l"
    end, { expr = true, desc = key.desc })
  else
    -- Through `:Changeset`, so a map takes the same route as the command, range and all.
    vim.keymap.set("n", lhs, ("<Cmd>Changeset %s<CR>"):format(key.name), { desc = key.desc })
  end
end
-- `:`, not <Cmd>, so the selection arrives as the '<,'> range.
vim.keymap.set("x", plug("comment new"), ":Changeset comment new<CR>", { silent = true, desc = comment_new.desc })
vim.keymap.set(
  "n",
  plug("review restore"),
  "<Cmd>Changeset review restore<CR>",
  { desc = "Bring back a batch of submitted review comments" }
)

-- which-key's name for each prefix the default keys share.
local GROUPS = { ["<C-g>c"] = "comment", ["<C-g>n"] = "navigation" }

---Whether a global map in `mode` has `lhs`, or starts it, or starts with it: either way `lhs` would clash with it.
---Buffer-local maps don't count, being only the buffer current at startup's.
---@param lhs string
---@param mode string
---@return boolean
local function taken(lhs, mode)
  -- Compared as keytrans spells them, as `lhs` reads in nvim_get_keymap: `lhsraw` holds <C-g> in another form.
  local spelled = vim.fn.keytrans(vim.keycode(lhs))
  return vim.iter(vim.api.nvim_get_keymap(mode)):any(function(map)
    return vim.startswith(map.lhs, spelled) or vim.startswith(spelled, map.lhs)
  end)
end

---Maps each default key not already taken, unless `vim.g.changeset_no_default_maps` is set.
local function map_defaults()
  if vim.g.changeset_no_default_maps then
    return
  end
  -- Decided before any default is mapped, which would all clash with it. A user's map that blocks `<C-g>cc` blocks it
  -- too.
  local pause = { n = not taken("<C-g>c", "n"), x = not taken("<C-g>c", "x") }
  -- The `<C-g>` keys mapped in normal mode, which the review comment window maps again on its own buffer. Not `]g`,
  -- which the window would map in insert mode too, where it is text.
  local window_keys = {}
  -- Every key mapped, as which-key specs that add its icon, and each group's name once one of its keys is.
  local icon_specs = {}
  local named = {}
  ---@param mode string
  ---@param lhs string
  ---@param key changeset.DefaultKey
  local function map(mode, lhs, key)
    vim.keymap.set(mode, lhs, plug(key.name), { desc = key.desc })
    -- A group's own key takes its group's spec: which-key keeps the last of two specs for one key, and names a key
    -- with keys under it after its desc unless its spec names the group.
    if not GROUPS[lhs] then
      icon_specs[#icon_specs + 1] = { lhs, mode = mode, icon = key.icon }
    end
    if mode == "n" and vim.startswith(lhs, "<C-g>") then
      window_keys[#window_keys + 1] = { lhs = lhs, name = key.name, desc = key.desc }
    end
    for prefix, group in pairs(GROUPS) do
      if vim.startswith(lhs, prefix) and not named[mode .. prefix] then
        named[mode .. prefix] = true
        icon_specs[#icon_specs + 1] = { prefix, mode = mode, group = group, icon = key.icon }
      end
    end
  end
  for _, key in ipairs(keys) do
    for _, mode in ipairs(key.modes or { "n" }) do
      if not taken(key.lhs, mode) then
        map(mode, key.lhs, key)
      end
    end
  end
  -- So a pause after the <C-g>c prefix comments, rather than leaving Select mode's or a pending `c`. Mapped last, or
  -- `cn` and `cp` would see it as a clash.
  for mode, comments in pairs(pause) do
    if comments then
      map(mode, "<C-g>c", comment_new)
    end
  end
  vim.g.changeset_window_keys = window_keys
  local has_which_key, which_key = pcall(require, "which-key")
  -- which-key v2 has no add().
  if has_which_key and which_key.add then
    which_key.add(icon_specs)
  end
end

local group = vim.api.nvim_create_augroup("changeset.plugin", {})

-- Fires: after a session is restored, which brings the sidebar's window back
-- without its contents. Refills it rather than leaving an empty window behind.
vim.api.nvim_create_autocmd("SessionLoadPost", {
  group = group,
  callback = function()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
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
