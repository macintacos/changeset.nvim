---Turns the changetree row model into buffer lines and the extmarks that colour them.
---
---Everything here is data in, data out: the caller supplies icons, collapse state
---and width, and applies the returned marks to a buffer itself.

local symbols = require("plugins.mini-pickers.symbols")

---@class changetree.Mark
---@field col integer          0-based byte column the mark starts at.
---@field end_col? integer     0-based exclusive byte column; absent on virtual-text marks.
---@field hl? string           Group over `col`..`end_col`; absent on virtual-text marks, whose chunks carry their own.
---@field virt_text? table[]   `nvim_buf_set_extmark` virtual-text chunks.
---@field pos? "inline"|"right_align" Where the virtual text is drawn.

---@class changetree.Line
---@field text string
---@field marks changetree.Mark[]
---@field row changetree.Row The row this line draws; a placeholder line carries the file it stands in for.

---@class changetree.RenderOpts
---@field icon fun(row: changetree.Row): string, string Glyph and its highlight group; the caller wraps `MiniIcons.get`.
---@field collapsed fun(id: string): boolean         Whether the row with this id hides its children.
---@field width integer                              Window width in cells; long names are trimmed so stats stay visible.

---@class changetree.Summary
---@field base_ref string  What the branch is compared against, e.g. "origin/trunk".
---@field files integer
---@field added integer
---@field removed integer

---@class changetree.Empty
---@field on_default_branch boolean
---@field branch string
---@field ref string      What the branch is compared against, e.g. "origin/trunk".

local M = {}

---Group for text that is not content: `Comment` with italics. Created by `define_highlights`.
---@type string
M.META_HL = "ChangeTreeMeta"

---Group for the band over a window the sidebar is previewing into. Created by `define_highlights`.
---@type string
M.PREVIEW_HL = "ChangeTreePreview"

---Group for the badge at the head of that band. Created by `define_highlights`.
---@type string
M.PREVIEW_LABEL_HL = "ChangeTreePreviewLabel"

---Group for the affordance at the tail of that band. Created by `define_highlights`.
---@type string
M.PREVIEW_HINT_HL = "ChangeTreePreviewHint"

-- Stands in at the tail of the preview band when the row names no destination.
local HINT = "<CR> to open"

---`%` introduces an item in a statusline, so anything interpolated into one is doubled.
---@param text string
---@return string
local function escaped(text)
  return (text:gsub("%%", "%%%%"))
end

local RAIL = "▎"

local RAIL_HL = {
  added = "GitSignsAdd",
  modified = "GitSignsChange",
  renamed = "GitSignsChange",
  deleted = "GitSignsDelete",
  untracked = "GitSignsUntracked",
}

local STATUS_MARKER = { deleted = " deleted", renamed = " renamed" }

local META_KINDS = { orphans = true, orphan = true }

---Joins highlighted chunks into a line, recording each chunk's byte range as a mark.
---@param row changetree.Row The row the line draws.
---@param chunks { [1]: string, [2]: string? }[] Text and, optionally, the group that colours it.
---@param stat? table[] Virtual-text chunks to right-align on the line.
---@return changetree.Line
local function compose(row, chunks, stat)
  local text, marks = "", {}
  for _, chunk in ipairs(chunks) do
    local piece, hl = chunk[1], chunk[2]
    if hl then
      marks[#marks + 1] = { col = #text, end_col = #text + #piece, hl = hl }
    end
    text = text .. piece
  end
  if stat then
    marks[#marks + 1] = { col = #text, virt_text = stat, pos = "right_align" }
  end
  return { text = text, marks = marks, row = row }
end

---The `+N -N` virtual text for a row.
---@param row changetree.Row
---@return table[]? chunks `nil` when the row has no stat of its own.
local function stat_chunks(row)
  if row.ancestor or (row.added == nil and row.removed == nil) then
    return nil
  end
  return {
    { "+" .. (row.added or 0), "GitSignsAdd" },
    { " " },
    { "-" .. (row.removed or 0), "GitSignsDelete" },
  }
end

---Cells a stat claims at the right edge, one more than its width for the gap before it.
---@param stat table[]? Virtual-text chunks.
---@return integer
local function stat_cells(stat)
  if not stat then
    return 0
  end
  local total = 1
  for _, chunk in ipairs(stat) do
    total = total + vim.fn.strdisplaywidth(chunk[1])
  end
  return total
end

---Cuts `text` to `room` cells, marking the cut with an ellipsis and keeping its head.
---@param text string
---@param room integer
---@return string
local function clip_right(text, room)
  if vim.fn.strdisplaywidth(text) <= room then
    return text
  end
  return vim.fn.strcharpart(text, 0, math.max(room - 1, 0)) .. "…"
end

---@param file changetree.Row
---@param opts changetree.RenderOpts
---@return changetree.Line
local function file_line(file, opts)
  local glyph, icon_hl = opts.icon(file)
  local marker = STATUS_MARKER[file.status]
  local stat = stat_chunks(file)
  local room = opts.width
    - vim.fn.strdisplaywidth(RAIL .. " " .. glyph .. " ")
    - (marker and vim.fn.strdisplaywidth(marker) or 0)
    - stat_cells(stat)
  local chunks = {
    { RAIL, RAIL_HL[file.status] },
    { " " },
    { glyph, icon_hl },
    { " " },
    { symbols.fit(file.path, room) },
  }
  if marker then
    chunks[#chunks + 1] = { marker, "Comment" }
  end
  return compose(file, chunks, stat)
end

---@param row changetree.Row
---@param guides string Tree connectors for the row, e.g. "│ └─".
---@param opts changetree.RenderOpts
---@return changetree.Line
local function child_line(row, guides, opts)
  local glyph, icon_hl = opts.icon(row)
  local stat = stat_chunks(row)
  local room = opts.width - vim.fn.strdisplaywidth("  " .. guides .. glyph .. " ") - stat_cells(stat)
  local name, name_hl = symbols.fit(row.name, room), row.ancestor and "Comment" or nil
  if META_KINDS[row.kind] then
    icon_hl, name, name_hl = M.META_HL, clip_right(row.name, room), M.META_HL
  end
  return compose(row, {
    { "  " },
    { guides, "Comment" },
    { glyph, icon_hl },
    { " " },
    { name, name_hl },
  }, stat)
end

---@param file changetree.Row The file the placeholder waits under.
---@return changetree.Line
local function placeholder_line(file)
  return compose(file, { { "  " }, { "└─", "Comment" }, { "⋯ reading symbols", M.META_HL } })
end

---@param out changetree.Line[]
---@param row changetree.Row
---@param bars string Ancestor bars this level's connectors hang off.
---@param opts changetree.RenderOpts
local function append_children(out, row, bars, opts)
  for i, child in ipairs(row.children) do
    local is_last = i == #row.children
    out[#out + 1] = child_line(child, bars .. (is_last and "└─" or "├─"), opts)
    if not opts.collapsed(child.id) then
      append_children(out, child, bars .. (is_last and "  " or "│ "), opts)
    end
  end
end

---@param out changetree.Line[]
---@param file changetree.Row
---@param opts changetree.RenderOpts
local function append_file(out, file, opts)
  out[#out + 1] = file_line(file, opts)
  if opts.collapsed(file.id) then
    return
  end
  -- A file with nothing under it is either waiting on a server or genuinely has
  -- nothing to show — a 100% rename, a binary change. Only the first gets the
  -- placeholder, so `resolved` is what decides it, not an empty child list.
  if not file.resolved and file.status ~= "deleted" then
    out[#out + 1] = placeholder_line(file)
  else
    append_children(out, file, "", opts)
  end
end

---Render file rows and everything visible under them, one buffer line per row.
---@param rows changetree.Row[] File rows, children nested.
---@param opts changetree.RenderOpts
---@return changetree.Line[]
function M.lines(rows, opts)
  local out = {}
  for _, file in ipairs(rows) do
    append_file(out, file, opts)
  end
  return out
end

---The winbar text: what the tree is compared against, then the file count and line totals.
---@param summary changetree.Summary
---@return string
function M.winbar(summary)
  local base = escaped(summary.base_ref)
  local noun = summary.files == 1 and "file" or "files"
  return (" vs %s%%=%d %s  +%d -%d "):format(base, summary.files, noun, summary.added, summary.removed)
end

---The winbar over a window the sidebar is borrowing: a band across the top
---saying the file under it is on loan, and which one it is.
---
---Reversed badge, then the path, then where `<CR>` would land — the three things
---a borrowed window has to answer, in the order they are asked.
---
---`%<` sits before the path because the path is the one part the sidebar is
---already showing: when the window is too narrow for all three, it is what a
---reader can most afford to lose.
---@param path string Display path of the previewed file.
---@param target string? What `<CR>` lands on; absent for a row that names nothing.
---@return string
function M.preview_winbar(path, target)
  return table.concat({
    ("%%#%s# Preview "):format(M.PREVIEW_LABEL_HL),
    ("%%#%s#  %%<%s"):format(M.PREVIEW_HL, escaped(path)),
    "%=",
    ("%%#%s#%s "):format(M.PREVIEW_HINT_HL, escaped(target or HINT)),
  })
end

---The sentence shown in place of the tree when there is nothing to list.
---@param info changetree.Empty
---@return string
function M.empty_message(info)
  if info.on_default_branch then
    return ("On %s — nothing to compare. Switch to a branch to see its changes."):format(info.branch)
  end
  return ("%s matches %s. Nothing changed yet."):format(info.branch, info.ref)
end

---Create the groups the sidebar draws with. `META_HL` is mixed from `Comment`
---rather than linked to it, which would drop the italics.
function M.define_highlights()
  local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
  vim.api.nvim_set_hl(0, M.META_HL, { fg = comment.fg, italic = true })

  -- Visual's background is the one tint every colorscheme gives a window to say
  -- "this is the thing you are on", so the band reads in any theme.
  local band = vim.api.nvim_get_hl(0, { name = "Visual", link = false }).bg
  local warn = vim.api.nvim_get_hl(0, { name = "DiagnosticWarn", link = false })
  vim.api.nvim_set_hl(0, M.PREVIEW_HL, { bg = band })
  -- `reverse` rather than a background read off `Normal`: it pairs the accent
  -- with whatever the window is actually drawn on, so the badge survives a
  -- theme that leaves `Normal` transparent.
  vim.api.nvim_set_hl(0, M.PREVIEW_LABEL_HL, { fg = warn.fg or comment.fg, reverse = true, bold = true })
  vim.api.nvim_set_hl(0, M.PREVIEW_HINT_HL, { fg = comment.fg, bg = band, italic = true })
end

return M
