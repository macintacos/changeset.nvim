---Opens and closes gitsigns' unified diff in the windows showing a file the tree lists, as far as the diff reaches.
---It draws the lines gone since gitsigns' base inline, as `:Gitsigns diffthis unified=true` does. `changeset.diff_reach`
---decides which files it reaches.

local build = require("changeset.build")
local diff_reach = require("changeset.diff_reach")
local highlights = require("changeset.highlights")
local Paths = require("changeset.paths")

local M = {}

local GROUP = "changeset.unified_diff"

-- The groups gitsigns draws the view with, each drawn as changeset's instead. Many themes give gitsigns' a flat
-- foreground, which hides the syntax colouring under it; changeset's are backgrounds alone.
local DIFF_HL = {
  GitSignsAddPreview = highlights.DIFF_ADD_HL,
  GitSignsAddInline = highlights.DIFF_ADD_TEXT_HL,
  -- A word changed on an added line is new text, as GitHub colours it.
  GitSignsChangeInline = highlights.DIFF_ADD_TEXT_HL,
  GitSignsDeleteInline = highlights.DIFF_DELETE_TEXT_HL,
  GitSignsDeleteVirtLn = highlights.DIFF_DELETE_HL,
  GitSignsDeleteVirtLnInLine = highlights.DIFF_DELETE_TEXT_HL,
  GitSignsVirtLnum = highlights.DIFF_DELETE_HL,
}

local reach = diff_reach.new()

---Whether the autocommands and decoration provider are set up, which they stay for the session.
local started = false

---Each window's view this module opened: its buffer and file, the buffer holding its base, and the base's text
---gitsigns held.
---@type table<integer, { buf: integer, path: string, base: integer, text: string[] }>
local opened = {}

---Each window with a view on its way, and the buffer it is for.
---@type table<integer, integer>
local opening = {}

---Each window's buffer holding the marks `cover` made in it.
---@type table<integer, integer>
local covered = {}

---gitsigns' `attach_to_untracked` as it was before the diff turned on, while the diff holds it on.
---@type boolean?
local untracked_was

-- Reaches into gitsigns internals: its buffer cache, its unified views, and the base buffer `diffthis` makes for them.

---@param win integer
---@return boolean
local function showing(win)
  return require("gitsigns.unified").get_view(win) ~= nil
end

---The absolute path of `name` when the tree lists that file, else nil.
---@param name string A buffer's name, or a path.
---@return string?
local function tree_file(name)
  local tree = build.current()
  if not tree then
    return nil
  end
  local path = Paths.relative(tree.root, name)
  if path and vim.iter(tree.files):any(function(file)
    return file.path == path
  end) then
    return tree.root .. "/" .. path
  end
end

---Whether the diff reaches the file `buf` holds.
---@param buf integer
---@return boolean
local function allowed(buf)
  local path = tree_file(vim.api.nvim_buf_get_name(buf))
  return path ~= nil and reach:allows(path)
end

---Whether the view this module opened in `win` went while `win` still shows its buffer, which only the user does.
---@param win integer
---@return boolean
local function closed_by_user(win)
  local mine = opened[win]
  return mine ~= nil and mine.buf == vim.api.nvim_win_get_buf(win) and not showing(win)
end

---Have gitsigns attach to untracked files, those loaded now included: the sidebar counts one as added, but gitsigns
---leaves it alone by default, so it would get no view.
local function attach_untracked()
  local config = require("gitsigns.config").config
  untracked_was = config.attach_to_untracked
  config.attach_to_untracked = true
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    -- gitsigns gives a buffer its status once it finds the buffer's repository, before deciding to attach.
    if
      vim.api.nvim_buf_is_loaded(buf)
      and vim.b[buf].gitsigns_status_dict
      and not require("gitsigns.cache").cache[buf]
    then
      require("gitsigns").attach({ bufnr = buf })
    end
  end
end

---Draw gitsigns' diff groups in `win` as changeset's, beside the window's own overrides. Sorted, so painting a window
---again leaves 'winhighlight' as it was.
---@param win integer
local function paint(win)
  local kept = vim.tbl_filter(function(pair)
    return DIFF_HL[pair:match("^[^:]*")] == nil
  end, vim.split(vim.wo[win].winhighlight, ",", { trimempty = true }))
  for from, to in vim.spairs(DIFF_HL) do
    kept[#kept + 1] = from .. ":" .. to
  end
  local value = table.concat(kept, ",")
  if vim.wo[win].winhighlight ~= value then
    vim.wo[win].winhighlight = value
  end
end

---Whether gitsigns' signs give way in `win` as it draws `buf`: while the file's view is this module's, open or yet to
---come, since gitsigns signs a file well before the view can draw.
---@param win integer
---@param buf integer
---@return boolean
local function covering(win, buf)
  local mine = opened[win]
  -- A view open that this module didn't open is the user's own; one of ours gone, the user closed.
  return reach:on() and vim.bo[buf].buftype == "" and showing(win) == (mine ~= nil and mine.buf == buf) and allowed(buf)
end

---Lay a blank sign over each of gitsigns' in rows `top` to `bot` of `buf`, and draw the sign and number of each line
---`added` names on its tint, keeping the marks in `ns` already right.
---@param buf integer
---@param ns integer
---@param top integer
---@param bot integer
---@param added Gitsigns.Hunk.Hunk[] The hunks the view draws.
local function cover(buf, ns, top, bot, added)
  local want = {} ---@type table<integer, string|false>
  -- Read off gitsigns' marks rather than its hunks: it signs each line those name as it comes into sight, after an edit
  -- moved them and before it diffs again.
  for _, name in ipairs({ "gitsigns_signs_", "gitsigns_signs_staged" }) do
    local signs = vim.api.nvim_create_namespace(name)
    for _, sign in ipairs(vim.api.nvim_buf_get_extmarks(buf, signs, { top, 0 }, { bot, -1 }, { details = true })) do
      if sign[4].sign_text then
        want[sign[2]] = false
      end
    end
  end
  for _, hunk in ipairs(added) do
    for row = math.max(hunk.added.start - 1, top), math.min(hunk.added.start + hunk.added.count - 2, bot) do
      want[row] = highlights.DIFF_ADD_HL
    end
  end
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { top, 0 }, { bot, -1 }, { details = true })) do
    if want[mark[2]] == (mark[4].sign_hl_group or false) then
      want[mark[2]] = nil
    else
      vim.api.nvim_buf_del_extmark(buf, ns, mark[1])
    end
  end
  -- Above gitsigns' signs, which the sign column then has no room for, and below diagnostics' by default.
  local priority = require("gitsigns.config").config.sign_priority + 1
  for row, hl in pairs(want) do
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
      sign_text = " ",
      sign_hl_group = hl or nil,
      number_hl_group = hl or nil,
      priority = priority,
    })
  end
end

---A view to open: the window, the buffer and file it shows, and the base gitsigns holds for the buffer.
---@class changeset.unified_diff.View
---@field win integer
---@field buf integer
---@field path string The file `buf` holds.
---@field git_obj Gitsigns.GitObj Names the base.
---@field text string[] The base's text.

---Show `view`'s buffer's unified diff in its window, replacing any view there.
---
---What `:Gitsigns diffthis unified=true` runs, with the window held: it takes the current window only once the base's
---buffer is made, which can wait on git, by when the sidebar may be current.
---@param view changeset.unified_diff.View
local function open(view)
  local win, buf, path, git_obj, text = view.win, view.buf, view.path, view.git_obj, view.text
  opening[win] = buf
  ---@async
  local function run()
    local _, base, created, loaded =
      require("gitsigns.actions.diffthis").create_revision_buf(git_obj.repo, git_obj.revision, git_obj.relpath, buf)
    opening[win] = nil
    if not base then
      return
    end
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf and reach:allows(path) then
      if table.concat(text, "\n") == "" then
        -- gitsigns writes a base without the file as one blank line, which the view reads back with its newline.
        vim.bo[base].endofline = false
      end
      -- Before `show`, which registers the view at once but then waits on its diff.
      opened[win] = { buf = buf, path = path, base = base, text = text }
      paint(win)
      require("gitsigns.unified").show(win, base, created, loaded)
    elseif created then
      vim.api.nvim_buf_delete(base, { force = true })
    end
  end
  require("gitsigns.async").run(run):raise_on_error()
end

---Open the unified diff in `win` when it reaches the file there, unless it is open there, or again once the base it
---compares against has moved.
---@param win integer
function M.sync(win)
  if not started then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if opened[win] and opened[win].buf ~= buf then
    opened[win] = nil
  end
  local path = tree_file(vim.api.nvim_buf_get_name(buf))
  if not (path and reach:allows(path)) then
    return
  end
  -- gitsigns drops a buffer's status before the last update it publishes as it lets go, mid-unload, of the buffer.
  local tracked = vim.bo[buf].buftype == "" and vim.b[buf].gitsigns_status_dict ~= nil
  local bcache = tracked and require("gitsigns.cache").cache[buf]
  if not (bcache and bcache.compare_text) or opening[win] == buf then
    return
  end
  local mine = opened[win]
  local view = { win = win, buf = buf, path = path, git_obj = bcache.git_obj, text = bcache.compare_text }
  if not showing(win) then
    -- One of ours gone while its buffer stays was closed by the user, which leaving the window acts on, or is going
    -- with a buffer being deleted, which publishes a last update first.
    if not mine then
      open(view)
    end
  -- A view this module didn't open is the user's own.
  elseif mine and mine.text ~= view.text then
    open(view)
  end
end

local function sync_all()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    M.sync(win)
  end
end

---Close at once, in every window, each view this module opened on a file `keeps` turns down.
---@param keeps fun(path: string): boolean
local function close_unless(keeps)
  for win, mine in pairs(opened) do
    if not keeps(mine.path) then
      opened[win] = nil
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == mine.buf then
        require("gitsigns.unified").close(win)
      end
    end
  end
end

---Set up what opens, closes and covers the views, once for the session: each answers the reach as it fires.
local function start()
  if started then
    return
  end
  started = true
  -- Fires: the tree reading its diff, which says which files it lists, the first time a little after the sidebar opens.
  -- Not before: a tree built anew lists no file until then.
  build.subscribe(function(event)
    if event == "diff" then
      close_unless(function(path)
        return tree_file(path) ~= nil
      end)
      sync_all()
    end
  end)
  local group = vim.api.nvim_create_augroup(GROUP, { clear = true })
  -- Fires: a window taking a buffer, a buffer or window entered, a split among them. Previews swap buffers where
  -- autocommands don't nest, so `window.preview` syncs its window itself.
  vim.api.nvim_create_autocmd({ "BufWinEnter", "BufEnter", "WinEnter" }, {
    group = group,
    desc = "changeset: open gitsigns' unified diff in the window the cursor is in",
    callback = function()
      M.sync(vim.api.nvim_get_current_win())
    end,
  })
  -- Fires: gitsigns publishing a buffer's counts or branch anew, as it attaches and mostly as its base moves, so a
  -- file opened before gitsigns read its base gets its view, and one whose base moved a fresh one; entering its
  -- window catches a move that left the counts alone.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "GitSignsUpdate",
    desc = "changeset: open gitsigns' unified diff in a buffer's windows once gitsigns has its base",
    callback = function(args)
      local buf = args.data and args.data.buffer
      for _, win in ipairs(buf and vim.fn.win_findbuf(buf) or {}) do
        M.sync(win)
      end
    end,
  })
  -- Fires: leaving a buffer or window, before gitsigns closes a view on the buffer leaving its window, so a view
  -- gone by then was closed by the user.
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    group = group,
    desc = "changeset: stop opening gitsigns' unified diff on a file once the user closes its view",
    callback = function()
      local win = vim.api.nvim_get_current_win()
      if closed_by_user(win) then
        local closed = opened[win].path
        reach:hand_close(closed)
        close_unless(function(path)
          return path ~= closed
        end)
      end
    end,
  })
  -- Fires: a buffer unloaded, a reload by `:e!` among them, which takes the views still on it or on its text as their
  -- base with it: those go without the user closing them. A view the user closed went first, releasing its base.
  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    desc = "changeset: reopen gitsigns' unified diff that went with an unloaded buffer",
    callback = function(args)
      for win, mine in pairs(opened) do
        if (mine.buf == args.buf or mine.base == args.buf) and showing(win) then
          opened[win] = nil
        end
      end
    end,
  })
  -- Fires: any window closing, which takes its view with it.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    desc = "changeset: forget the unified diff of a closed window",
    callback = function(args)
      local win = tonumber(args.match) --[[@as integer]]
      opened[win], covered[win], opening[win] = nil, nil, nil
    end,
  })
  -- gitsigns signs a buffer and draws a view's hunks anew with no event to say so, but always redraws the window after.
  -- Providers run in the order their namespaces were made, so gitsigns', made as this loaded gitsigns, signs the lines
  -- coming into sight before this covers them.
  vim.api.nvim_set_decoration_provider(vim.api.nvim_create_namespace(GROUP), {
    on_win = function(_, win, buf, top, bot)
      local was, now = covered[win], covering(win, buf) and buf or nil
      if was == nil and now == nil then
        return false
      end
      -- One per window, which alone draws it: the same buffer may show in a window without a view.
      local ns = vim.api.nvim_create_namespace(GROUP .. "." .. win)
      if was and was ~= now and vim.api.nvim_buf_is_valid(was) then
        vim.api.nvim_buf_clear_namespace(was, ns, 0, -1)
      end
      covered[win] = now
      if now then
        if was ~= now then
          vim.api.nvim__ns_set(ns, { wins = { win } })
        end
        local view = require("gitsigns.unified").get_view(win)
        cover(buf, ns, top, math.min(bot, vim.api.nvim_buf_line_count(buf) - 1), view and view.hunks or {})
      end
      return false
    end,
  })
end

---Whether gitsigns is there, with unified views.
---@return boolean
function M.available()
  return (pcall(require, "gitsigns.unified"))
end

---Reach every file the tree lists, those closed by hand included, opening their views in every window now and from
---now on. Without a gitsigns that has unified views, it stays as it is.
function M.turn_on()
  if not M.available() then
    return
  end
  local was_on = reach:on()
  reach:turn_on()
  start()
  if not was_on then
    attach_untracked()
  end
  sync_all()
end

---Reach no further than `keep` says, never further than now, closing at once, in every window, each view this module
---opened that the diff no longer reaches.
---@param keep changeset.DiffReach.Keep
function M.limit(keep)
  reach:limit(keep)
  close_unless(function(path)
    return reach:allows(path)
  end)
  if untracked_was ~= nil and not reach:on() then
    require("gitsigns.config").config.attach_to_untracked = untracked_was
    untracked_was = nil
  end
end

---Note that the user entered the file at `path`, for the rest of the session, opening its views where the diff now
---reaches it. A file the tree doesn't list isn't entered.
---@param path string A buffer's name, or a path.
function M.enter(path)
  local file = tree_file(path)
  if file and reach:enter(file) then
    sync_all()
  end
end

---Whether the diff reaches any file.
---@return boolean
function M.on()
  return reach:on()
end

return M
