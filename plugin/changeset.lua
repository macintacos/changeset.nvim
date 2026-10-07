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
    require("changeset").step(1)
  end,
  prev = function()
    require("changeset").step(-1)
  end,
  ["next-comment"] = function()
    require("changeset.reviewing").next_comment(1)
  end,
  ["prev-comment"] = function()
    require("changeset.reviewing").prev_comment(1)
  end,
  ["last-comment"] = function()
    require("changeset.reviewing").last_comment()
  end,
  list = function()
    require("changeset.reviewing").list()
  end,
  yank = function()
    require("changeset.reviewing").yank()
  end,
}

---The review comment window, when it is current. Never loads its module: no window is open until it is loaded.
---@return changeset.ReviewCommentWindow?
local function comment_window()
  local module = package.loaded["changeset.review_comment_window"]
  return module and module.current()
end

vim.api.nvim_create_user_command("Changeset", function(opts)
  local name = opts.args == "" and "toggle" or opts.args
  local run = subcommands[name]
  if not run then
    return vim.notify("Changeset: unknown subcommand " .. opts.args, vim.log.levels.ERROR)
  end
  local open = comment_window()
  if open then
    return require("changeset.reviewing").from_window(open, name, function()
      run(opts)
    end)
  end
  run(opts)
end, {
  nargs = "?",
  range = true,
  bar = true,
  desc = "Toggle the changeset sidebar, rebuild it, toggle PR Review Mode, step through and open its changes, or write, delete, walk, reopen, list, copy, abandon or submit review comments",
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
  { "cc", "comment", "Comment on this line, or the selection, or edit the comment there", { "n", "x" } },
  { "cn", "next-comment", "Next review comment" },
  { "cp", "prev-comment", "Previous review comment" },
  { "cl", "last-comment", "Edit the review comment you saved last" },
  { "d", "delete", "Delete the review comment on this line" },
  { "n", "next", "Open the next change" },
  { "p", "prev", "Open the previous change" },
  { "l", "list", "List the review comments in the quickfix list" },
  { "y", "yank", "Copy the review as text" },
  { "s", "submit", "Submit the review to an agent" },
  { "a", "abandon", "Abandon the review" },
  { "t", "toggle", "Toggle the changeset sidebar" },
  { "r", "refresh", "Rebuild the changeset sidebar" },
  { "m", "review", "Toggle PR Review Mode" },
}

---The steps `.` repeats: each one's `'operatorfunc'` call, `%d` standing for the count.
local repeatable = {
  next = "v:lua.require'changeset'.step(%d)",
  prev = "v:lua.require'changeset'.step(-%d)",
  ["next-comment"] = "v:lua.require'changeset.reviewing'.next_comment(%d)",
  ["prev-comment"] = "v:lua.require'changeset.reviewing'.prev_comment(%d)",
}

for _, key in ipairs(keys) do
  local name, desc = key[2], key[3]
  local lhs = ("<Plug>(changeset-%s)"):format(name)
  local call = repeatable[name]
  if call then
    -- A g@ operator is what `.` repeats. The count is baked into the lambda, and <Esc> drops the typed one, so `.`
    -- repeats the first count.
    vim.keymap.set("n", lhs, function()
      if comment_window() then
        return ("<Cmd>Changeset %s<CR>"):format(name)
      end
      vim.o.operatorfunc = ("{_ -> %s}"):format(call:format(vim.v.count1))
      return "<Esc>g@l"
    end, { expr = true, desc = desc })
  else
    -- Through `:Changeset`, so a map takes the same route as the command, range and all.
    vim.keymap.set("n", lhs, ("<Cmd>Changeset %s<CR>"):format(name), { desc = desc })
  end
end
-- `:`, not <Cmd>, so the selection arrives as the '<,'> range.
vim.keymap.set("x", "<Plug>(changeset-comment)", ":Changeset comment<CR>", { silent = true, desc = keys[1][3] })

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

---Maps each default `<C-g>` key not already taken, unless `vim.g.changeset_no_default_maps` is set.
local function map_defaults()
  if vim.g.changeset_no_default_maps then
    return
  end
  -- Decided before any default is mapped, which would all clash with it. A user's map that blocks `<C-g>cc` blocks it
  -- too.
  local pause = { n = not taken("<C-g>c", "n"), x = not taken("<C-g>c", "x") }
  -- The keys mapped in normal mode, which the review comment window maps again on its own buffer.
  local window_keys = {}
  ---@param lhs string
  ---@param name string
  ---@param desc string
  local function offer(lhs, name, desc)
    window_keys[#window_keys + 1] = { lhs = lhs, name = name, desc = desc }
  end
  for _, key in ipairs(keys) do
    local lhs = "<C-g>" .. key[1]
    for _, mode in ipairs(key[4] or { "n" }) do
      if not taken(lhs, mode) then
        vim.keymap.set(mode, lhs, ("<Plug>(changeset-%s)"):format(key[2]), { desc = key[3] })
        if mode == "n" then
          offer(lhs, key[2], key[3])
        end
      end
    end
  end
  -- So a pause after the <C-g>c prefix comments, rather than leaving Select mode's or a pending `c`. Mapped last, or
  -- `cn` and `cp` would see it as a clash.
  for mode, comments in pairs(pause) do
    if comments then
      vim.keymap.set(mode, "<C-g>c", "<Plug>(changeset-comment)", { desc = keys[1][3] })
      if mode == "n" then
        offer("<C-g>c", "comment", keys[1][3])
      end
    end
  end
  vim.g.changeset_window_keys = window_keys
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
