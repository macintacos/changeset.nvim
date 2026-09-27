---The changeset sidebar's rows as a picker, each change under a breadcrumb of what holds it.
---
---A row that only places a change — a file with rows beneath it, an ancestor
---symbol, the "Other changes" group — is not an item but part of the trail
---printed above the items it holds, the way the live grep hoists a hit's path. A
---deleted file is left out: there is nothing to open.

local preview = require("plugins.mini-pickers.preview")
local render = require("plugins.mini-pickers.render")
local stats = require("plugins.changeset.render")
local symbols = require("plugins.mini-pickers.symbols")

local M = {}

local SEP = " › "

---@class MiniPickers.ChangesetItem
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
---@return MiniPickers.ChangesetItem[]
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
  local ok, glyph, hl = pcall(MiniIcons.get, category, name)
  return ok and glyph or " ", ok and hl or "Normal"
end

---`source.show`: each item's name under its icon, its stat right-aligned, and its
---trail printed above it wherever the trail changes. Score order can scatter a
---file's items, so a trail is reprinted rather than assumed from further up.
---@param buf_id integer
---@param list MiniPickers.ChangesetItem[]
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

  vim.api.nvim_buf_clear_namespace(buf_id, render.ns, 0, -1)
  local prev_trail, first_has_trail = nil, false
  for i, item in ipairs(list) do
    vim.api.nvim_buf_set_extmark(buf_id, render.ns, i - 1, 0, {
      end_col = #icons[i],
      hl_group = hls[i],
      priority = 199,
    })
    vim.api.nvim_buf_set_extmark(buf_id, render.ns, i - 1, 0, {
      virt_text = stats.stat_chunks(item.row),
      virt_text_pos = "right_align",
      priority = 199,
    })

    if item.trail ~= "" then
      if item.trail ~= prev_trail then
        local glyph, hl = icon("file", item.row.path)
        vim.api.nvim_buf_set_extmark(buf_id, render.ns, i - 1, 0, {
          -- Split on "/" so a long trail sheds directories before the file or its symbols.
          virt_lines = { { { glyph .. " ", hl }, { symbols.fit(item.trail, width - 2, "/"), render.crumb_hl() } } },
          virt_lines_above = true,
          priority = 199,
        })
        first_has_trail = first_has_trail or i == 1
      end
      vim.api.nvim_buf_set_extmark(buf_id, render.ns, i - 1, 0, {
        virt_text = { { "  " } },
        virt_text_pos = "inline",
        priority = 199,
      })
    end
    prev_trail = item.trail
  end

  if state then
    render.reserve_trail_row(state.windows.main, first_has_trail)
  end
end

-- Exposed for tests: which rows become items, and how their trails are drawn.
M._items = items
M._show = show

---Open the picker on the changeset of the current buffer's repository.
function M.pick()
  local tree, err = require("plugins.changeset").rows()
  if not tree then
    return vim.notify("Changeset: " .. err, vim.log.levels.WARN)
  end
  return MiniPick.start({
    source = { items = items(tree.rows, tree.root), name = "Changeset (vs " .. tree.ref .. ")", show = show },
    window = preview.window(),
  })
end

return M
