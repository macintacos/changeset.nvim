---Turns the changeset row model into buffer lines and the extmarks that colour them.
---
---Everything here is data in, data out: the caller supplies icons, collapse state
---and width, and applies the returned marks to a buffer itself.

local symbols = require("plugins.mini-pickers.symbols")

---@class changeset.Mark
---@field priority? integer    Draw order against the row's other marks; `MARK_PRIORITY` stands when absent.
---@field col integer          0-based byte column the mark starts at.
---@field end_col? integer     0-based exclusive byte column; absent on virtual-text marks.
---@field hl? string           Group over `col`..`end_col`; absent on virtual-text marks, whose chunks carry their own.
---@field virt_text? table[]   `nvim_buf_set_extmark` virtual-text chunks.
---@field pos? "inline"|"right_align" Where the virtual text is drawn.

---@class changeset.Line
---@field text string
---@field marks changeset.Mark[]
---@field row changeset.Row The row this line draws; a placeholder's stands in for its file.

---@class changeset.RenderOpts
---@field icon fun(row: changeset.Row): string, string Glyph and its highlight group; the caller wraps `MiniIcons.get`.
---@field collapsed fun(id: string): boolean         Whether the row with this id hides its children.
---@field width integer                              Window width in cells; long names and directories are trimmed so stats stay visible.
---@field query? string                               Filter text; every occurrence of it in a line is marked.

---@class changeset.Summary
---@field base_ref string  What the branch is compared against, e.g. "origin/trunk".
---@field files integer
---@field added integer
---@field removed integer

---@class changeset.Band The strip over a window the sidebar is previewing into.
---@field icon string       Glyph for the previewed file's type.
---@field icon_hl string    Group to draw it in, from `band_icon`.
---@field path string       Repo-relative path of the previewed file.
---@field destination string? What `<CR>` lands on; absent for a row that names nothing.

---@class changeset.Empty
---@field on_default_branch boolean
---@field branch string
---@field ref string      What the branch is compared against, e.g. "origin/trunk".

local M = {}

---Group for text that is not content: `Comment` with italics. Created by `define_highlights`.
---@type string
M.META_HL = "ChangesetMeta"

---Group for the band over a window the sidebar is previewing into. Created by `define_highlights`.
---@type string
M.PREVIEW_HL = "ChangesetPreview"

---Group for the badge at the head of that band. Created by `define_highlights`.
---@type string
M.PREVIEW_LABEL_HL = "ChangesetPreviewLabel"

---Group for the affordance at the tail of that band. Created by `define_highlights`.
---@type string
M.PREVIEW_HINT_HL = "ChangesetPreviewHint"

---Group for the run of characters a filter query matched. Created by `define_highlights`.
---@type string
M.MATCH_HL = "ChangesetMatch"

---Group for a symbol kind the tree is not showing. Created by `define_highlights`.
---@type string
M.HIDDEN_HL = "ChangesetHidden"

---Group for the sidebar's own header strip. Created by `define_highlights`.
---@type string
M.HEADER_HL = "ChangesetHeader"

---Group for the badge at the head of that strip. Created by `define_highlights`.
---@type string
M.HEADER_LABEL_HL = "ChangesetHeaderLabel"

---Background of the row last picked from the sidebar. Created by `define_highlights`.
---@type string
M.SELECTED_HL = "ChangesetSelected"

---Background of the row for the file and line the cursor is in. Created by `define_highlights`.
---@type string
M.HERE_HL = "ChangesetHere"

---Group for the filetype glyph on the preview band. Recoloured by `band_icon`.
---@type string
M.PREVIEW_ICON_HL = "ChangesetPreviewIcon"

---The priority a mark draws at when it carries none of its own. The magnitude is
---arbitrary — only the steps to the row backgrounds below and the match above matter.
---@type integer
M.MARK_PRIORITY = 199

-- Above the marks a row already carries, so a match reads over a dimmed
-- ancestor and a coloured symbol name alike.
local MATCH_PRIORITY = M.MARK_PRIORITY + 1

---Row backgrounds draw beneath every row mark; a selection over "you are here".
---@type integer
M.HERE_PRIORITY = M.MARK_PRIORITY - 2
---@type integer
M.SELECTED_PRIORITY = M.MARK_PRIORITY - 1

-- Stands in at the tail of the preview band when the row names no destination.
local HINT = "<CR> to open"

---`%` introduces an item in a statusline, so anything interpolated into one is doubled.
---@param text string
---@return string
local function escaped(text)
  return (text:gsub("%%", "%%%%"))
end

local RAIL = "▎"

-- The two kinds whose plural is not just an `s`. The rest split on the camel hump
-- ("EnumMember" reads as two words) and take one.
local PLURAL = { Class = "classes", Property = "properties" }

---@param kind string
---@return string
local function plural(kind)
  return PLURAL[kind] or ((kind:gsub("(%l)(%u)", "%1 %2")):lower() .. "s")
end

---@param names string[]
---@return string
local function sentence_list(names)
  if #names < 2 then
    return names[1] or ""
  end
  return table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end

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
---@param row changeset.Row? The row the line draws; absent on a line that draws no row.
---@param chunks { [1]: string, [2]: string? }[] Text and, optionally, the group that colours it.
---@param stat? table[] Virtual-text chunks to right-align on the line.
---@return changeset.Line
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
---@param row changeset.Row
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

---A file row: filename first, its directory dimmed in parentheses, dropped before the name is trimmed.
---@param file changeset.Row
---@param opts changeset.RenderOpts
---@return changeset.Line
local function file_line(file, opts)
  local glyph, icon_hl = opts.icon(file)
  local marker = STATUS_MARKER[file.status]
  local stat = stat_chunks(file)
  local room = opts.width
    - vim.fn.strdisplaywidth(RAIL .. " " .. glyph .. " ")
    - (marker and vim.fn.strdisplaywidth(marker) or 0)
    - stat_cells(stat)
  local filename, dir = vim.fs.basename(file.path), vim.fs.dirname(file.path)
  local dir_room = room - vim.fn.strdisplaywidth(filename .. " ()")
  local chunks = {
    { RAIL, RAIL_HL[file.status] },
    { " " },
    { glyph, icon_hl },
    { " " },
  }
  if dir ~= "." and dir_room >= 1 then
    vim.list_extend(chunks, { { filename }, { " " }, { "(" .. symbols.fit(dir, dir_room, "/") .. ")", "Comment" } })
  else
    chunks[#chunks + 1] = { symbols.fit(filename, room) }
  end
  if marker then
    chunks[#chunks + 1] = { marker, "Comment" }
  end
  return compose(file, chunks, stat)
end

---@param row changeset.Row
---@param guides string Tree connectors for the row, e.g. "│ └─".
---@param opts changeset.RenderOpts
---@return changeset.Line
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

---@param file changeset.Row The file the placeholder waits under.
---@return changeset.Line
local function placeholder_line(file)
  -- A row of its own, one level down. Two lines under one id would make the file read as
  -- childless to `h` and to the cursor anchor, both of which go by the next line's depth.
  local row = vim.tbl_extend("force", file, {
    id = file.id .. "\0#pending",
    depth = file.depth + 1,
    children = {},
  })
  return compose(row, { { "  " }, { "└─", "Comment" }, { "⋯ reading symbols", M.META_HL } })
end

---@param out changeset.Line[]
---@param row changeset.Row
---@param bars string Ancestor bars this level's connectors hang off.
---@param opts changeset.RenderOpts
local function append_children(out, row, bars, opts)
  for i, child in ipairs(row.children) do
    local is_last = i == #row.children
    out[#out + 1] = child_line(child, bars .. (is_last and "└─" or "├─"), opts)
    if not opts.collapsed(child.id) then
      append_children(out, child, bars .. (is_last and "  " or "│ "), opts)
    end
  end
end

---@param out changeset.Line[]
---@param file changeset.Row
---@param opts changeset.RenderOpts
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

---Byte ranges of every occurrence of `query` in `text`, case-insensitively.
---
---Read off the rendered line rather than the row's name: a name is trimmed to
---fit, and the point is to mark the characters that are actually on screen.
---@param text string
---@param query string
---@return { [1]: integer, [2]: integer }[] 0-based, end exclusive.
local function matches(text, query)
  if query == "" then
    return {}
  end
  -- `string.lower` leaves every byte above ASCII alone, so folding both sides
  -- keeps the offsets it finds valid in the original.
  local haystack, needle = text:lower(), query:lower()
  local found, from = {}, 1
  while true do
    local first, last = haystack:find(needle, from, true)
    if not first then
      return found
    end
    found[#found + 1] = { first - 1, last }
    from = last + 1
  end
end

---Render file rows and everything visible under them, one buffer line per row.
---@param rows changeset.Row[] File rows, children nested.
---@param opts changeset.RenderOpts
---@return changeset.Line[]
function M.lines(rows, opts)
  local out = {}
  for _, file in ipairs(rows) do
    append_file(out, file, opts)
  end
  for _, line in ipairs(out) do
    for _, span in ipairs(matches(line.text, opts.query or "")) do
      line.marks[#line.marks + 1] = { col = span[1], end_col = span[2], hl = M.MATCH_HL, priority = MATCH_PRIORITY }
    end
  end
  return out
end

---@class changeset.KindRow One symbol kind's standing in the tree.
---@field kind string    LSP kind name, e.g. "Method".
---@field count integer  Symbol rows of this kind, whether hidden or not.
---@field hidden boolean

---@class changeset.KindLine
---@field text string
---@field marks changeset.Mark[]
---@field kind string The kind this line stands for.

---@class changeset.KindOpts
---@field icon fun(kind: string): string, string Glyph and its highlight group.
---@field width integer Cells the menu is wide.

---One line per symbol kind: a rail while it is showing, its count at the right edge.
---
---Column 0 is the rail the file rows already use, carrying kind colour here where
---they carry change type — so the menu reads as part of the tree rather than as a
---checkbox list. A hidden kind loses the rail *and* is struck through: the rail's
---absence alone is a negative signal, and dimming alone is what ancestor rows
---already mean.
---@param rows changeset.KindRow[]
---@param opts changeset.KindOpts
---@return changeset.KindLine[]
function M.kind_lines(rows, opts)
  local out = {}
  for i, row in ipairs(rows) do
    local glyph, icon_hl = opts.icon(row.kind)
    local count, lead = tostring(row.count), row.hidden and " " or RAIL
    local gap = opts.width
      - vim.fn.strdisplaywidth(lead .. " " .. glyph .. " " .. row.kind)
      - vim.fn.strdisplaywidth(count)
    local line = compose(nil, {
      { lead, not row.hidden and icon_hl or nil },
      { " " },
      { glyph, row.hidden and M.HIDDEN_HL or icon_hl },
      { " " },
      { row.kind, row.hidden and M.HIDDEN_HL or nil },
      { (" "):rep(math.max(gap, 1)) },
      { count, M.META_HL },
    })
    line.kind = row.kind
    out[i] = line
  end
  return out
end

---Hidden kind names as prose: pluralised, lowercased, joined for a sentence.
---@param kinds string[]
---@return string
function M.kind_list(kinds)
  return sentence_list(vim.tbl_map(plural, kinds))
end

---The footnote under the tree when part of it is not being shown.
---
---Names the kinds while they fit, because which ones are missing is what stops a
---reader hunting for a symbol that is present. Past the width it counts them
---instead: a clipped list answers nothing.
---@param kinds string[] Hidden kinds the tree actually has.
---@param width integer Cells available under the tree.
---@return string? nil when nothing is hidden.
function M.hidden_note(kinds, width)
  if #kinds == 0 then
    return nil
  end
  local named = ("Hiding %s. F to change."):format(M.kind_list(kinds))
  if vim.fn.strdisplaywidth(named) <= width then
    return named
  end
  return ("Hiding %d kinds of symbol. F to change."):format(#kinds)
end

---The sidebar's header: what the tree is compared against worn as a badge, then
---the file count and line totals at the right edge.
---
---Badge over a band, the shape the strip over a borrowed window uses, because
---both answer "what is this window holding" before anything in it.
---@param summary changeset.Summary
---@return string
function M.header(summary)
  local noun = summary.files == 1 and "file" or "files"
  return table.concat({
    ("%%#%s# vs %s "):format(M.HEADER_LABEL_HL, escaped(summary.base_ref)),
    ("%%#%s#%%=%d %s  +%d -%d "):format(M.HEADER_HL, summary.files, noun, summary.added, summary.removed),
  })
end

---The winbar over a window the sidebar is borrowing: a band across the top
---saying the file under it is on loan, and which one it is.
---
---Reversed badge, then the file's own icon and path, then where `<CR>` would
---land — what a borrowed window has to answer, in the order it is asked.
---
---`%<` sits before the path because the path is the one part the sidebar is
---already showing: when the window is too narrow for all three, it is what a
---reader can most afford to lose.
---@param band changeset.Band
---@return string
function M.preview_winbar(band)
  return table.concat({
    ("%%#%s# Preview "):format(M.PREVIEW_LABEL_HL),
    -- The spaces belong to the icon's group rather than the band's, which keeps
    -- the two one highlight run and the icon one cell off the badge either way.
    ("%%#%s# %s "):format(band.icon_hl, band.icon),
    ("%%#%s#%%<%s"):format(M.PREVIEW_HL, escaped(band.path)),
    "%=",
    ("%%#%s#%s "):format(M.PREVIEW_HINT_HL, escaped(band.destination or HINT)),
  })
end

---Point `PREVIEW_ICON_HL` at `hl`'s colour over the band's background.
---
---A MiniIcons group carries a foreground only, so a glyph drawn straight in one
---punches the window's own background through the band. One group recoloured per
---preview rather than one per filetype: only ever one band is on screen.
---@type string? The group the band's glyph last came with, so a new colorscheme can
---be followed: this one is mixed from two resolved colours rather than linked to them.
local band_hl

---@param hl string Group the glyph came with.
---@return string group
function M.band_icon(hl)
  band_hl = hl
  vim.api.nvim_set_hl(0, M.PREVIEW_ICON_HL, {
    fg = vim.api.nvim_get_hl(0, { name = hl, link = false }).fg,
    bg = vim.api.nvim_get_hl(0, { name = M.PREVIEW_HL, link = false }).bg,
  })
  return M.PREVIEW_ICON_HL
end

---The sentence shown in place of the tree when there is nothing to list.
---@param info changeset.Empty
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

  -- CursorLine's background is the faintest tint every colorscheme gives a window
  -- to say "this is the thing you are on", so the band reads in any theme without
  -- competing with the file under it. Visual is the same idea two shades louder,
  -- and stands in for a theme that leaves CursorLine to the number column.
  local cursorline = vim.api.nvim_get_hl(0, { name = "CursorLine", link = false })
  local visual = vim.api.nvim_get_hl(0, { name = "Visual", link = false })
  local band = cursorline.bg or visual.bg
  local warn = vim.api.nvim_get_hl(0, { name = "DiagnosticWarn", link = false })
  vim.api.nvim_set_hl(0, M.PREVIEW_HL, { bg = band })
  -- `reverse` rather than a background read off `Normal`: it pairs the accent
  -- with whatever the window is actually drawn on, so the badge survives a
  -- theme that leaves `Normal` transparent.
  vim.api.nvim_set_hl(0, M.PREVIEW_LABEL_HL, { fg = warn.fg or comment.fg, reverse = true, bold = true })
  vim.api.nvim_set_hl(0, M.PREVIEW_HINT_HL, { fg = comment.fg, bg = band, italic = true })
  -- TabLine's background is what a colorscheme paints its own chrome with, so the
  -- header reads as the panel's frame. Not the band's shade: the sidebar draws its
  -- cursor line in exactly that, and a header the colour of a row is a row.
  local chrome = vim.api.nvim_get_hl(0, { name = "TabLine", link = false }).bg or band
  vim.api.nvim_set_hl(0, M.HEADER_HL, { bg = chrome })
  -- Directory's colour rather than the badge's warning yellow: this badge says
  -- what the panel is, and yellow is already spoken for by "on loan".
  local directory = vim.api.nvim_get_hl(0, { name = "Directory", link = false })
  vim.api.nvim_set_hl(0, M.HEADER_LABEL_HL, { fg = directory.fg or comment.fg, reverse = true, bold = true })
  -- What the editor already paints over the text you searched for.
  vim.api.nvim_set_hl(0, M.MATCH_HL, { link = "Search" })
  -- Struck through as well as dimmed: dim on its own is what ancestor rows mean,
  -- and it reads as faint rather than as switched off in a light colourscheme.
  vim.api.nvim_set_hl(0, M.HIDDEN_HL, { fg = comment.fg, strikethrough = true })
  vim.api.nvim_set_hl(0, M.SELECTED_HL, { bg = visual.bg or cursorline.bg })
  -- ColorColumn before CursorLine for "here": the sidebar draws its own cursor line
  -- in CursorLine, and a second row that shade reads as a second cursor.
  vim.api.nvim_set_hl(0, M.HERE_HL, {
    bg = vim.api.nvim_get_hl(0, { name = "ColorColumn", link = false }).bg or cursorline.bg,
  })
  -- Last, over the band it is drawn on: a glyph left on the old theme's colour is
  -- the one thing here that can come out invisible rather than merely off-key.
  if band_hl then
    M.band_icon(band_hl)
  end
end

return M
