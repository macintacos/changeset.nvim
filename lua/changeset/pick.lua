---The changeset sidebar's rows as a picker, each change under a breadcrumb of what holds it.
---
---A row that only places a change — a file with rows beneath it, an ancestor
---symbol, the "Other changes" group — is not an item but part of the trail
---printed as a virtual line above the items it holds. A deleted file is left
---out: there is nothing to open.

local highlights = require("changeset.highlights")
local icons = require("changeset.icons")
local pick_preview = require("changeset.pick_preview")
local render = require("changeset.render")
local symbols = require("changeset.symbols")

local M = {}

local ns = vim.api.nvim_create_namespace("changeset.pick")

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
      local here = trail == "" and row.name or trail .. symbols.SEP .. row.name
      if is_change(row) then
        out[#out + 1] = { text = here, trail = trail, path = root .. "/" .. row.path, lnum = row.lnum, row = row }
      end
      walk(row.children, here)
    end
  end
  walk(rows, "")
  return out
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
  local glyphs, hls, display = {}, {}, {}
  for i, item in ipairs(list) do
    local row = item.row
    if row.kind == "file" then
      glyphs[i], hls[i] = icons.get("file", row.path)
    else
      glyphs[i], hls[i] = icons.get("lsp", row.symbol_kind or "Text")
    end
    display[i] = glyphs[i] .. " " .. row.name
  end

  MiniPick.default_show(buf_id, display, query)

  local state = MiniPick.get_picker_state()
  local width = state and vim.api.nvim_win_get_width(state.windows.main) or 80

  vim.api.nvim_buf_clear_namespace(buf_id, ns, 0, -1)
  local prev_trail, first_has_trail = nil, false
  for i, item in ipairs(list) do
    vim.api.nvim_buf_set_extmark(buf_id, ns, i - 1, 0, {
      end_col = #glyphs[i],
      hl_group = hls[i],
      priority = 199,
    })
    vim.api.nvim_buf_set_extmark(buf_id, ns, i - 1, 0, {
      virt_text = render.stat_chunks(item.row),
      virt_text_pos = "right_align",
      priority = 199,
    })

    if item.trail ~= "" then
      if item.trail ~= prev_trail then
        local glyph, hl = icons.get("file", item.row.path)
        vim.api.nvim_buf_set_extmark(buf_id, ns, i - 1, 0, {
          -- Split on "/" so a long trail sheds directories before the file or its symbols.
          virt_lines = { { { glyph .. " ", hl }, { symbols.fit(item.trail, width - 2, "/"), highlights.META_HL } } },
          virt_lines_above = true,
          priority = 199,
        })
        first_has_trail = first_has_trail or i == 1
      end
      vim.api.nvim_buf_set_extmark(buf_id, ns, i - 1, 0, {
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
---Needs mini.pick set up; warns and returns otherwise. Blocks until the picker closes.
---@return changeset.PickItem? chosen
function M.pick()
  -- `require` first so a lazy-loading manager can load and set mini.pick up; then
  -- `MiniPick`, which only `setup()` creates and `MiniPick.start` needs.
  if not (pcall(require, "mini.pick") and MiniPick) then
    return vim.notify("Changeset: the picker needs mini.pick set up", vim.log.levels.WARN)
  end
  local tree, err = require("changeset").rows()
  if not tree then
    return vim.notify("Changeset: " .. err, vim.log.levels.WARN)
  end
  -- Here, not at require time: the sidebar defines its groups only when it opens,
  -- and nothing may touch MiniPick before the guard.
  highlights.define_highlights()
  pick_preview.setup()
  return MiniPick.start({
    source = { items = items(tree.rows, tree.root), name = "Changeset (vs " .. tree.ref .. ")", show = show },
    window = pick_preview.window(),
  })
end

return M
