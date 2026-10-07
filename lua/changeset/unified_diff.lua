---Opens gitsigns' unified diff in every file window once the sidebar has opened, until the user closes one.
---It draws the lines gone since gitsigns' base inline, as `:Gitsigns diffthis unified=true` does. Closing one in any
---window turns it off everywhere until Neovim exits.

local render = require("changeset.render")

local M = {}

local GROUP = "changeset.unified_diff"

-- The groups gitsigns draws the view with, each drawn as changeset's instead. Many themes give gitsigns' a flat
-- foreground, which hides the syntax colouring under it; changeset's are backgrounds alone.
local DIFF_HL = {
  GitSignsAddPreview = render.DIFF_ADD_HL,
  GitSignsAddInline = render.DIFF_ADD_TEXT_HL,
  -- A word changed on an added line is new text, as GitHub colours it.
  GitSignsChangeInline = render.DIFF_ADD_TEXT_HL,
  GitSignsDeleteInline = render.DIFF_DELETE_TEXT_HL,
  GitSignsDeleteVirtLn = render.DIFF_DELETE_HL,
  GitSignsDeleteVirtLnInLine = render.DIFF_DELETE_TEXT_HL,
  GitSignsVirtLnum = render.DIFF_DELETE_HL,
}

---@type "waiting"|"on"|"off"
local state = "waiting"

---Each window's view this module opened: its buffer, the buffer holding its base, and the base's text gitsigns held.
---@type table<integer, { buf: integer, base: integer, text: string[] }>
local opened = {}

---Each window with a view on its way, and the buffer it is for.
---@type table<integer, integer>
local opening = {}

-- Reaches into gitsigns internals: its buffer cache, its unified views, and the base buffer `diffthis` makes for them.

---@param win integer
---@return boolean
local function showing(win)
  return require("gitsigns.unified").get_view(win) ~= nil
end

---Whether the view this module opened in `win` went while `win` still shows its buffer, which only the user does.
---@param win integer
---@return boolean
local function closed_by_user(win)
  local mine = opened[win]
  return mine ~= nil and mine.buf == vim.api.nvim_win_get_buf(win) and not showing(win)
end

local function turn_off()
  state = "off"
  opened = {}
  vim.api.nvim_clear_autocmds({ group = GROUP })
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

---Show `buf`'s unified diff in `win`, replacing any view there, against the base `git_obj` names.
---
---What `:Gitsigns diffthis unified=true` runs, with the window held: it takes the current window only once the base's
---buffer is made, which can wait on git, by when the sidebar may be current.
---@param win integer
---@param buf integer
---@param git_obj Gitsigns.GitObj
---@param text string[] The base's text gitsigns holds.
local function open(win, buf, git_obj, text)
  opening[win] = buf
  ---@async
  local function run()
    local _, base, created, loaded =
      require("gitsigns.actions.diffthis").create_revision_buf(git_obj.repo, git_obj.revision, git_obj.relpath, buf)
    opening[win] = nil
    if not base then
      return
    end
    if state == "on" and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      -- Before `show`, which registers the view at once but then waits on its diff.
      opened[win] = { buf = buf, base = base, text = text }
      paint(win)
      require("gitsigns.unified").show(win, base, created, loaded)
    elseif created then
      vim.api.nvim_buf_delete(base, { force = true })
    end
  end
  require("gitsigns.async").run(run):raise_on_error()
end

---Open the unified diff in `win`, unless it is open there, or again once the base it compares against has moved.
---@param win integer
function M.sync(win)
  if state ~= "on" then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if opened[win] and opened[win].buf ~= buf then
    opened[win] = nil
  end
  -- gitsigns drops a buffer's status before the last update it publishes as it lets go, mid-unload, of the buffer.
  local tracked = vim.bo[buf].buftype == "" and vim.b[buf].gitsigns_status_dict ~= nil
  local bcache = tracked and require("gitsigns.cache").cache[buf]
  if not (bcache and bcache.compare_text) or opening[win] == buf then
    return
  end
  local mine = opened[win]
  if not showing(win) then
    -- One of ours gone while its buffer stays was closed by the user, which leaving the window acts on, or is going
    -- with a buffer being deleted, which publishes a last update first.
    if not mine then
      open(win, buf, bcache.git_obj, bcache.compare_text)
    end
  -- A view this module didn't open is the user's own.
  elseif mine and mine.text ~= bcache.compare_text then
    open(win, buf, bcache.git_obj, bcache.compare_text)
  end
end

---Open the unified diff in every file window from now on, those open now included. Does nothing without a gitsigns
---that has it, while already on, or once the user has closed it.
function M.activate()
  if state ~= "waiting" or not pcall(require, "gitsigns.unified") then
    return
  end
  state = "on"
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
    desc = "changeset: stop opening gitsigns' unified diff once the user closes one",
    callback = function()
      if closed_by_user(vim.api.nvim_get_current_win()) then
        turn_off()
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
      opened[tonumber(args.match)] = nil
    end,
  })
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    M.sync(win)
  end
end

return M
