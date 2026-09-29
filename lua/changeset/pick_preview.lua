---Side-by-side preview for mini.pick.
---
---mini.pick draws its preview in place of the list, in the picker's one window.
---This hangs a second float right of the list instead and keeps it showing the
---current item. The picker's own `source.preview` fills it: `default_preview`
---positions the cursor in whichever window shows the buffer it is handed, so a
---location item lands on its line here too.
---
---`require("changeset.pick").pick()` calls `setup()` and passes `window = window()`
---to `MiniPick.start`, which also narrows the list to leave room. Below
---`MIN_COLUMNS` the list takes the whole width and no float opens; the in-place
---toggle still works.

local window = require("changeset.window")

local M = {}

---Editor width below which there is no room for a preview beside the list.
M.MIN_COLUMNS = 120

local LIST_RATIO = 0.4

-- Each float's border takes a column either side.
local BORDERS = 4

---Split the editor width between the list and the preview.
---@param columns integer
---@return { list: integer, preview?: integer } layout Widths inside the borders.
function M._layout(columns)
  if columns < M.MIN_COLUMNS then
    return { list = columns }
  end
  local list = math.floor(LIST_RATIO * columns)
  return { list = list, preview = columns - list - BORDERS }
end

---Float config for a preview of `width` columns beside the list window.
---@param list vim.api.keyset.win_config The list window's current config.
---@param width integer
---@return vim.api.keyset.win_config
function M._float_config(list, width)
  return {
    relative = "editor",
    anchor = list.anchor,
    row = list.row,
    col = list.col + list.width + 2,
    width = width,
    height = list.height,
    border = list.border,
    zindex = list.zindex,
    style = "minimal",
    focusable = false,
  }
end

local function window_config()
  return { width = M._layout(vim.o.columns).list }
end

---Picker `window` option that opts into the side preview.
---@return table
function M.window()
  return { config = window_config }
end

---A fresh buffer for one preview; wiped as soon as the next replaces it.
---@return integer
local function scratch()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  return buf
end

---Keep a side preview in step with the active picker until it stops.
---@param preview fun(buf_id: integer, item: any) The picker's `source.preview`.
---@param main integer The picker's list window.
local function attach(preview, main)
  local ns = vim.api.nvim_create_namespace("changeset.pick_preview")
  local group = vim.api.nvim_create_augroup("changeset.pick_preview_session", { clear = true })
  local win, shown

  local function render()
    local matches = MiniPick.is_picker_active() and MiniPick.get_picker_matches()
    local item = matches and matches.current
    if not (win and vim.api.nvim_win_is_valid(win)) or item == shown then
      return
    end
    shown = item
    local buf = scratch()
    vim.api.nvim_win_set_buf(win, buf)
    if item ~= nil then
      preview(buf, item)
      vim.api.nvim_win_call(win, window._reveal_cursor)
    end
    -- mini.pick has already redrawn for this key and is blocked in getcharstr,
    -- which does not repaint on its own.
    vim.cmd.redraw()
  end

  -- Opens, moves, or closes the float to fit the current editor width.
  local function place()
    local width = M._layout(vim.o.columns).preview
    local open = win and vim.api.nvim_win_is_valid(win)
    if not (width and vim.api.nvim_win_is_valid(main)) then
      if open then
        vim.api.nvim_win_close(win, true)
      end
      win = nil
      return
    end
    local config = M._float_config(vim.api.nvim_win_get_config(main), width)
    if open then
      vim.api.nvim_win_set_config(win, config)
    else
      win = vim.api.nvim_open_win(scratch(), false, vim.tbl_extend("force", config, { noautocmd = true }))
      shown = nil
    end
    render()
  end

  local function detach()
    vim.on_key(nil, ns)
    vim.api.nvim_del_augroup_by_id(group)
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  -- mini.pick emits no event when the current item moves, but every move is a
  -- key it reads. Scheduled so the picker has handled the key before we look.
  vim.on_key(function()
    vim.schedule(render)
  end, ns)

  -- Refresh the preview when matching lands: a query change resets the current
  -- item without a move key.
  vim.api.nvim_create_autocmd("User", { group = group, pattern = "MiniPickMatch", callback = render })

  -- Scheduled: mini.pick refits the list from its own `VimResized` handler.
  vim.api.nvim_create_autocmd("VimResized", { group = group, callback = vim.schedule_wrap(place) })

  vim.api.nvim_create_autocmd("User", { group = group, pattern = "MiniPickStop", once = true, callback = detach })

  place()
end

---Attach a side preview to every picker started with `window = M.window()`.
function M.setup()
  -- Opt-in check on every picker start: `get_picker_opts` copies the options,
  -- but functions survive the copy, so our `window.config` is still ours.
  vim.api.nvim_create_autocmd("User", {
    group = vim.api.nvim_create_augroup("changeset.pick_preview", { clear = true }),
    pattern = "MiniPickStart",
    callback = function()
      local opts, state = MiniPick.get_picker_opts(), MiniPick.get_picker_state()
      if opts and state and opts.window.config == window_config then
        attach(opts.source.preview, state.windows.main)
      end
    end,
  })
end

return M
