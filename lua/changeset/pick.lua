---The changeset sidebar's rows as a picker, each change under a breadcrumb of what holds it.
---
---A row that only places a change — a file with rows beneath it, an ancestor
---symbol, the "Other changes" group — is not an item but part of the trail
---printed above the items it holds, the way the live grep hoists a hit's path. A
---deleted file is left out: there is nothing to open.

local pick_preview = require("changeset.pick_preview")
local stats = require("changeset.render")
local symbols = require("changeset.symbols")

local M = {}

M.ns = vim.api.nvim_create_namespace("changeset.pick")

local SEP = " › "

---@class changeset.PickItem
---@field text string  The trail and the row's name, which is what a query matches.
---@field trail string The rows holding this one, file first; "" for a file with nothing beneath it.
---@field path string  Absolute.
---@field lnum integer?
---@field row changeset.Row

---Whether a row is a change of its own rather than only a place for others.
---@param row changeset.Row
---@return boolean
local function is_change(row)
  if row.kind == "file" then
    return #row.children == 0 and row.status ~= "deleted"
  end
  return row.kind == "orphan" or (row.kind == "symbol" and not row.ancestor)
end

---@param rows changeset.Row[] File rows, uncompressed, as `changeset.rows()` hands them over.
---@param root string Repository the rows' paths are relative to.
---@return changeset.PickItem[]
local function items(rows, root)
  local out = {}
  local function walk(list, trail)
    for _, row in ipairs(list) do
      local here = trail == "" and row.name or trail .. SEP .. row.name
      if is_change(row) then
        out[#out + 1] = { text = here, trail = trail, path = root .. "/" .. row.path, lnum = row.lnum, row = row }
      end
      walk(row.children, here)
    end
  end
  walk(rows, "")
  return out
end

---@param category string MiniIcons category.
---@param name string
---@return string glyph
---@return string hl
local function icon(category, name)
  -- The call is wrapped, not `MiniIcons.get`: an argument is evaluated before `pcall`
  -- runs, so indexing a missing mini.icons would raise past the fallback below.
  local ok, glyph, hl = pcall(function()
    return MiniIcons.get(category, name)
  end)
  return ok and glyph or " ", ok and hl or "Normal"
end

---Reserve (or release) a display row above the window's first line.
---
---Neovim clips a `virt_lines_above` mark on the topline: the line is part of
---the layout (`nvim_win_text_height` counts it) but there is nowhere to draw
---it, so `topfill` has to reserve the row. Without this the breadcrumb above
---the *first* result is silently missing while every other one renders.
---
---Call it after `MiniPick.default_show`, on every render: rewriting the lines
---drops `topfill`, and mini.pick draws the frame as soon as `source.show`
---returns. Deferring it paints the list a row off first, a visible jump.
---@param win integer
---@param needed boolean Whether the first line carries a trail.
function M._reserve_trail_row(win, needed)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  local want = needed and 1 or 0
  vim.api.nvim_win_call(win, function()
    if vim.fn.winsaveview().topfill ~= want then
      vim.fn.winrestview({ topfill = want })
    end
  end)
end

---`source.show`: each item's name under its icon, its stat right-aligned, and its
---trail printed above it wherever the trail changes. Score order can scatter a
---file's items, so a trail is reprinted rather than assumed from further up.
---@param buf_id integer
---@param list changeset.PickItem[]
---@param query string[]
local function show(buf_id, list, query)
  local icons, hls, display = {}, {}, {}
  for i, item in ipairs(list) do
    local row = item.row
    if row.kind == "file" then
      icons[i], hls[i] = icon("file", row.path)
    else
      icons[i], hls[i] = icon("lsp", row.symbol_kind or "Text")
    end
    display[i] = icons[i] .. " " .. row.name
  end

  MiniPick.default_show(buf_id, display, query)

  local state = MiniPick.get_picker_state()
  local width = state and vim.api.nvim_win_get_width(state.windows.main) or 80

  vim.api.nvim_buf_clear_namespace(buf_id, M.ns, 0, -1)
  local prev_trail, first_has_trail = nil, false
  for i, item in ipairs(list) do
    vim.api.nvim_buf_set_extmark(buf_id, M.ns, i - 1, 0, {
      end_col = #icons[i],
      hl_group = hls[i],
      priority = 199,
    })
    vim.api.nvim_buf_set_extmark(buf_id, M.ns, i - 1, 0, {
      virt_text = stats.stat_chunks(item.row),
      virt_text_pos = "right_align",
      priority = 199,
    })

    if item.trail ~= "" then
      if item.trail ~= prev_trail then
        local glyph, hl = icon("file", item.row.path)
        vim.api.nvim_buf_set_extmark(buf_id, M.ns, i - 1, 0, {
          -- Split on "/" so a long trail sheds directories before the file or its symbols.
          virt_lines = { { { glyph .. " ", hl }, { symbols.fit(item.trail, width - 2, "/"), stats.META_HL } } },
          virt_lines_above = true,
          priority = 199,
        })
        first_has_trail = first_has_trail or i == 1
      end
      vim.api.nvim_buf_set_extmark(buf_id, M.ns, i - 1, 0, {
        virt_text = { { "  " } },
        virt_text_pos = "inline",
        priority = 199,
      })
    end
    prev_trail = item.trail
  end

  if state then
    M._reserve_trail_row(state.windows.main, first_has_trail)
  end
end

-- Exposed for tests: which rows become items, and how their trails are drawn.
M._items = items
M._show = show

---Open the picker on the changeset of the current buffer's repository.
function M.pick()
  if not rawget(_G, "MiniPick") then
    vim.notify("Changeset: the picker needs mini.pick", vim.log.levels.WARN)
    return
  end
  local tree, err = require("changeset").rows()
  if not tree then
    return vim.notify("Changeset: " .. err, vim.log.levels.WARN)
  end
  stats.define_highlights()
  pick_preview.setup()
  return MiniPick.start({
    source = { items = items(tree.rows, tree.root), name = "Changeset (vs " .. tree.ref .. ")", show = show },
    window = pick_preview.window(),
  })
end

return M
