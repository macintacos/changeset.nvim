---The sign-column bar a borrowed window draws over the span its preview stands for.

local highlights = require("changeset.highlights")
local unified_diff = require("changeset.unified_diff")

local M = {}

local GROUP = "changeset.preview_bar"

local BAR = "┃"

---The rows a preview stands for, 1-based and inclusive, and the glyph its first row wears.
---@class changeset.BarSpan
---@field first integer
---@field last integer
---@field icon string
---@field icon_hl string

---The bar each window shows, and the buffer its marks sit in.
---@type table<integer, { buf: integer, span: changeset.BarSpan }>
local shown = {}

---The namespace of `win`'s marks. One per window, so a buffer shown in another window draws none of them.
---@param win integer
---@return integer
function M._namespace(win)
  return vim.api.nvim_create_namespace(GROUP .. "." .. win)
end

---Above gitsigns' signs and the covers over them, below diagnostics' default of 10, so a diagnostic still shows on
---the body.
---@return integer
local function priority()
  local ok, config = pcall(require, "gitsigns.config")
  return (ok and config.config.sign_priority or 6) + 2
end

---The groups a tinted row draws in: the bar's, and the icon's, each over the added tint.
---@param span changeset.BarSpan
---@return { bar: string, icon: string }
local function tint_groups(span)
  return {
    bar = highlights.tinted(highlights.PREVIEW_BAR_TINT_HL, highlights.PREVIEW_BAR_HL),
    icon = highlights.tinted(highlights.PREVIEW_BAR_ICON_TINT_HL, span.icon_hl),
  }
end

---The glyph and group `span` draws on `row` (0-based), in `tint` when the unified diff tints the row.
---@param span changeset.BarSpan
---@param row integer
---@param tint { bar: string, icon: string }?
---@return string glyph
---@return string group
local function drawn(span, row, tint)
  if row == span.first - 1 and span.icon:find("%S") then
    return span.icon, tint and tint.icon or span.icon_hl
  end
  return BAR, tint and tint.bar or highlights.PREVIEW_BAR_HL
end

---Mark the rows of `bar` that `top` to `bot` (0-based, inclusive) show in `win`, where the marks differ from what they
---should be.
---@param win integer
---@param bar { buf: integer, span: changeset.BarSpan }
---@param top integer
---@param bot integer
local function paint(win, bar, top, bot)
  local buf, namespace, span = bar.buf, M._namespace(win), bar.span
  local first = math.max(span.first - 1, top)
  local last = math.min(span.last - 1, bot, vim.api.nvim_buf_line_count(buf) - 1)
  if first > last then
    return
  end
  local tinted = unified_diff.tinted_rows(win, buf, first, last)
  local tint = next(tinted) and tint_groups(span) or nil
  local have = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, namespace, { first, 0 }, { last, -1 }, { details = true })) do
    have[mark[2]] = mark[4]
  end
  local level = priority()
  for row = first, last do
    local glyph, group = drawn(span, row, tinted[row] and tint or nil)
    local mark = have[row]
    -- Neovim pads a sign's text to its two cells, so the glyph is compared without the padding. Set only where it
    -- differs: a mark set again with the same content redraws the window.
    if not (mark and vim.trim(mark.sign_text) == glyph and mark.sign_hl_group == group) then
      vim.api.nvim_buf_set_extmark(buf, namespace, row, 0, {
        id = row + 1,
        sign_text = glyph,
        sign_hl_group = group,
        priority = level,
      })
    end
  end
end

-- Repaints on every redraw, as the tint can change with the unified diff's view, which may open after the preview.
vim.api.nvim_set_decoration_provider(vim.api.nvim_create_namespace(GROUP), {
  on_win = function(_, win, buf, top, bot)
    local bar = shown[win]
    if bar and bar.buf == buf then
      paint(win, bar, top, bot)
    end
    return false
  end,
})

---Set `span` as `win`'s bar over `buf`, in place of the one `win` showed. It is drawn on the next redraw.
---@param win integer
---@param buf integer
---@param span changeset.BarSpan
function M.show(win, buf, span)
  M.clear(win)
  shown[win] = { buf = buf, span = span }
  -- Scoped to `win`, as `unified_diff` scopes its covers: another window on `buf` shows none of it.
  vim.api.nvim__ns_set(M._namespace(win), { wins = { win } })
end

---Take the bar off `win`, once the preview it was drawn for has gone.
---@param win integer
function M.clear(win)
  local bar = shown[win]
  shown[win] = nil
  if bar and vim.api.nvim_buf_is_valid(bar.buf) then
    vim.api.nvim_buf_clear_namespace(bar.buf, M._namespace(win), 0, -1)
  end
end

return M
