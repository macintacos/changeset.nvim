---Turns the changeset row model into buffer lines and the extmarks that colour them.
---
---Everything here is data in, data out: the caller supplies icons, collapse state
---and width, and applies the returned marks to a buffer itself.

local cells = require("changeset.cells")
local highlights = require("changeset.highlights")
local review_comment = require("changeset.review_comment")
local symbols = require("changeset.symbols")

---@class changeset.Mark
---@field priority? integer    Draw order against the row's other marks; `MARK_PRIORITY` stands when absent.
---@field col integer          0-based byte column the mark starts at.
---@field end_col? integer     0-based exclusive byte column; absent on virtual-text marks.
---@field hl? string|string[]  Group or groups over `col`..`end_col`; absent on virtual-text marks, whose chunks carry their own.
---@field virt_text? table[]   `nvim_buf_set_extmark` virtual-text chunks.
---@field pos? "inline"|"right_align" Where the virtual text is drawn.
---@field hl_mode? "combine" Lays the virtual text over the line's background instead of blanking it.
---@field virt_lines? table[]  `nvim_buf_set_extmark` virtual lines, hung below the line.

---@class changeset.Line
---@field text string
---@field marks changeset.Mark[]
---@field row changeset.Row The row this line draws; a placeholder's stands in for its file.
---@field kind? string

---@class changeset.RenderOpts
---@field icon fun(row: changeset.Row): string, string Glyph and its highlight group.
---@field collapsed fun(id: string): boolean         Whether the row with this id hides its children.
---@field width integer                              Window width in cells; long names and directories are trimmed so stats stay visible.
---@field query? string                               Filter text; every occurrence of it in a line is marked.

---@class changeset.Summary
---@field ref string        What the branch is compared against, e.g. "origin/trunk".
---@field pr integer?       Number of the branch's open PR, when it merges into `ref`.
---@field files integer
---@field commits integer?  Commits on the branch since it forked from `ref`.
---@field added integer
---@field removed integer
---@field reading { done: integer, total: integer }? Present while symbols are still being read.

---@class changeset.Footer
---@field file integer?  Which of the files shown the cursor is in; absent when it is in none.
---@field files integer  Files shown.
---@field query string   Filter in force; empty for none.
---@field keys changeset.Config.Keymaps The keys the sidebar bound.

---@class changeset.Band The strip over a window the sidebar is previewing into.
---@field icon string       Glyph for the previewed file's type.
---@field icon_hl string    Group to draw it in, from `band_icon`.
---@field path string       Repo-relative path of the previewed file.
---@field destination string? What the right edge says: where the jump key lands, or why it opens nothing; absent for a row that names nothing.
---@field jump (string|false)? The jump key the sidebar bound; absent or `false` for none.

---@class changeset.Empty
---@field on_default_branch boolean
---@field branch string
---@field ref string      What the branch is compared against, e.g. "origin/trunk".

local M = {}

for name, value in pairs(highlights) do
  M[name] = value
end

---Glyph heading the Comments section: the file marks' bubble, borrowed as they borrow it, since no icon plugin has a
---category to ask for a comment.
---@type string
M.COMMENTS_ICON = highlights.REVIEW_COMMENT_BUBBLE

---Glyph at the right edge of the selected row.
---@type string
M.SELECTED_ICON = "◀"

---Glyph at the right edge of the row for where you are: the selection's, hollowed out.
---@type string
M.HERE_ICON = "◁"

---Glyph at the right edge of the row last opened from the sidebar.
---@type string
M.PICKED_ICON = "•"

---The priority a mark draws at when it carries none of its own. The magnitude is
---arbitrary — only the steps to the row backgrounds below and the match above matter.
---@type integer
M.MARK_PRIORITY = 199

-- Above the marks a row already carries, so a match reads over a dimmed
-- ancestor and a coloured symbol name alike.
local MATCH_PRIORITY = M.MARK_PRIORITY + 1

-- Beneath every row mark, so the rail, the row colours and a filter match stay on top.
local TINT_PRIORITY = M.MARK_PRIORITY - 1

-- Over the stat: its right-aligned text ends in the gutter's blanks, which would
-- otherwise be drawn over the glyph.
local GLYPH_PRIORITY = MATCH_PRIORITY + 1

-- Cells every row leaves at the right edge for a state glyph: a gap, then the glyph.
local GUTTER = 2

-- Stands in at the tail of the preview band when the row names no destination.
local HINT = "%s to open"

---`%` introduces an item in a statusline, so anything interpolated into one is doubled.
---@param text string
---@return string
local function escaped(text)
  return (text:gsub("%%", "%%%%"))
end

local RAIL = "▎"

-- Opens every tree row, so its icons line up under the header's.
local MARGIN = " "

-- The branch and diff glyphs are the ones mini.statusline already draws.
local BRANCH_ICON = ""
local PR_ICON = ""
local FILES_ICON = ""
local COMMIT_ICON = ""
local FILTER_ICON = "󰈲"

-- The actions the footer offers, `help` last since it lists the rest.
local HINTS = { { "jump", "open" }, { "filter", "filter" }, { "filter_kinds", "kinds" }, { "help", "all keys" } }

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
---@param chunks { [1]: string, [2]: string|string[]|nil }[] Text and, optionally, the group or groups that colour it.
---@param stat? table[] Virtual-text chunks to right-align on the line.
---@return changeset.Line
function M.compose(row, chunks, stat)
  local text, marks = "", {}
  for _, chunk in ipairs(chunks) do
    -- A buffer line can't hold a line break, which a symbol name or a path can. Same byte length, so marks stay put.
    local piece, hl = (chunk[1]:gsub("[\r\n]", " ")), chunk[2]
    if hl then
      marks[#marks + 1] = { col = #text, end_col = #text + #piece, hl = hl }
    end
    text = text .. piece
  end
  if stat then
    local padded = vim.list_extend(vim.list_slice(stat), { { (" "):rep(GUTTER) } })
    marks[#marks + 1] = { col = #text, virt_text = padded, pos = "right_align", hl_mode = "combine" }
  end
  return { text = text, marks = marks, row = row }
end

---The `+N -N` virtual text for a row.
---@param row changeset.Row
---@return table[]? chunks `nil` when the row has no stat of its own.
function M.stat_chunks(row)
  if row.ancestor or (row.added == nil and row.removed == nil) then
    return nil
  end
  return {
    { "+" .. (row.added or 0), "GitSignsAdd" },
    { " " },
    { "-" .. (row.removed or 0), "GitSignsDelete" },
  }
end

---The marks that show a row's state: its tint to the window's edge, and its glyph
---in the gutter every row leaves there.
---@param state "selected"|"here"|"picked"
---@param width integer The window's width.
---@return vim.api.keyset.set_extmark[]
function M.state_marks(state, width)
  local look = ({
    selected = { M.SELECTED_HL, M.SELECTED_ICON, M.SELECTED_ICON_HL },
    here = { M.HERE_HL, M.HERE_ICON, M.HERE_ICON_HL },
    picked = { M.PICKED_HL, M.PICKED_ICON, M.PICKED_ICON_HL },
  })[state]
  return {
    { hl_group = look[1], hl_eol = true, priority = TINT_PRIORITY },
    {
      virt_text = { { look[2], look[3] } },
      virt_text_win_col = width - 1,
      hl_mode = "combine",
      priority = GLYPH_PRIORITY,
    },
  }
end

---Cells a row gives up at the right edge: the state gutter, then a stat and the gap before it.
---@param stat table[]? Virtual-text chunks.
---@return integer
local function stat_cells(stat)
  if not stat then
    return GUTTER
  end
  local total = GUTTER + 1
  for _, chunk in ipairs(stat) do
    total = total + vim.fn.strdisplaywidth(chunk[1])
  end
  return total
end

---A file row: filename first, its directory dimmed in parentheses, dropped before the name is trimmed.
---@param file changeset.Row
---@param opts changeset.RenderOpts
---@return changeset.Line
local function file_line(file, opts)
  local glyph, icon_hl = opts.icon(file)
  local marker = STATUS_MARKER[file.status]
  local stat = M.stat_chunks(file)
  local room = opts.width
    - vim.fn.strdisplaywidth(MARGIN .. RAIL .. " " .. glyph .. " ")
    - (marker and vim.fn.strdisplaywidth(marker) or 0)
    - stat_cells(stat)
  local filename, dir = vim.fs.basename(file.path), vim.fs.dirname(file.path)
  local dir_room = room - vim.fn.strdisplaywidth(filename .. " ()")
  local chunks = {
    { MARGIN },
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
  return M.compose(file, chunks, stat)
end

-- Cells a section label is padded to, so every section header's count starts in one column.
local LABEL_CELLS = 20

---A section header: icon, label, a count of its files or comments, and the section's stat at the right edge. No rail.
---@param section changeset.Row
---@param opts changeset.RenderOpts
---@return changeset.Line
local function section_line(section, opts)
  local glyph, icon_hl = opts.icon(section)
  local stat = M.stat_chunks(section)
  local n, noun = section.comments or section.files, section.comments and "comment" or "file"
  local count = ("%d %s%s"):format(n, noun, n == 1 and "" or "s")
  if (section.drafts or 0) > 0 then
    count = ("%s · %d draft%s"):format(count, section.drafts, section.drafts == 1 and "" or "s")
  end
  local fixed_cells = vim.fn.strdisplaywidth(MARGIN .. glyph .. "  " .. section.name .. count) + stat_cells(stat)
  local pad = math.max(1, math.min(LABEL_CELLS - vim.fn.strdisplaywidth(section.name), opts.width - fixed_cells))
  return M.compose(section, {
    { MARGIN },
    { glyph, icon_hl },
    { "  " },
    { section.name .. (" "):rep(pad) },
    { count, M.META_HL },
  }, stat)
end

---@param row changeset.Row
---@param guides string Tree connectors for the row, e.g. "│ └─".
---@param opts changeset.RenderOpts
---@return changeset.Line
local function child_line(row, guides, opts)
  local glyph, icon_hl = opts.icon(row)
  local stat = M.stat_chunks(row)
  local room = opts.width - vim.fn.strdisplaywidth(MARGIN .. "  " .. guides .. glyph .. " ") - stat_cells(stat)
  local name, name_hl = symbols.fit(row.name, room), row.ancestor and "Comment" or nil
  if META_KINDS[row.kind] then
    icon_hl, name, name_hl = M.META_HL, cells.clip(row.name, room), M.META_HL
  end
  return M.compose(row, {
    { MARGIN },
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
  return M.compose(row, { { MARGIN }, { "  " }, { "└─", "Comment" }, { "⋯ reading symbols", M.META_HL } })
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

---A comment row: the file marks' circle in the rail's column, the file's icon, its name and line, the name alone for
---a whole file's, and the body's first line, quiet like the marks' and clipped to fit.
---@param row changeset.Row
---@param opts changeset.RenderOpts
---@return changeset.Line
local function comment_line(row, opts)
  local comment = assert(row.review_comment, "changeset: a comment row lists nothing")
  local glyph, icon_hl = opts.icon(row)
  local span = review_comment.span(comment)
  local where = vim.fs.basename(row.path) .. (span and ":" .. span or "")
  local circle = comment.draft and M.REVIEW_COMMENT_DRAFT_CIRCLE or M.REVIEW_COMMENT_CIRCLE
  local room = opts.width - vim.fn.strdisplaywidth(MARGIN .. circle .. " " .. glyph .. " ") - stat_cells(nil)
  where = cells.clip(where, room)
  local chunks = {
    { MARGIN },
    { circle, M.review_comment_hl(comment) },
    { " " },
    { glyph, icon_hl },
    { " " .. where },
  }
  room = room - vim.fn.strdisplaywidth(where)
  -- The body needs its two-cell gap and a cell to show anything.
  if room >= 3 then
    local text = cells.clip(comment.body:match("^[^\r\n]*"), room - 2)
    vim.list_extend(chunks, { { "  " }, { text, M.REVIEW_COMMENT_BODY_HL } })
  end
  return M.compose(row, chunks)
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
  -- placeholder, so the read status decides it, not an empty child list.
  if file.read == "reading" then
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

---Render section rows and everything visible under them, one buffer line per row.
---@param rows changeset.Row[] Section rows, children nested.
---@param opts changeset.RenderOpts
---@return changeset.Line[]
function M.lines(rows, opts)
  local out = {}
  for i, section in ipairs(rows) do
    if i > 1 then
      local marks = out[#out].marks
      marks[#marks + 1] = { col = 0, virt_lines = { { { "" } } } }
    end
    out[#out + 1] = section_line(section, opts)
    if not opts.collapsed(section.id) then
      for _, child in ipairs(section.children) do
        if child.kind == "comment" then
          out[#out + 1] = comment_line(child, opts)
        else
          append_file(out, child, opts)
        end
      end
    end
  end
  for _, line in ipairs(out) do
    -- A section header never matches the filter: lighting its label would claim a match.
    if line.row.kind ~= "section" then
      for _, run in ipairs(matches(line.text, opts.query or "")) do
        line.marks[#line.marks + 1] = { col = run[1], end_col = run[2], hl = M.MATCH_HL, priority = MATCH_PRIORITY }
      end
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
    local line = M.compose(nil, {
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
---@param key string|false? The key bound to the kind menu; without one the note offers none.
---@return string? nil when nothing is hidden.
function M.hidden_note(kinds, width, key)
  if #kinds == 0 then
    return nil
  end
  local hint = key and (" %s to change."):format(key) or ""
  local named = ("Hiding %s.%s"):format(M.kind_list(kinds), hint)
  if vim.fn.strdisplaywidth(named) <= width then
    return named
  end
  return ("Hiding %d kinds of symbol.%s"):format(#kinds, hint)
end

---The header's first row, for the sidebar's winbar: the ref the tree is compared
---against, and the branch's PR at the right edge.
---
---A ref too long for the width loses its tail, not its head: a stacked branch is
---told apart by the start of its name. The statusline's own `%<` would cut the
---other way.
---@param summary { ref: string, pr: integer? }
---@param width integer Cells the winbar spans.
---@return string
function M.header(summary, width)
  local pr = summary.pr and ("%s #%d"):format(PR_ICON, summary.pr)
  local room = width
    - vim.fn.strdisplaywidth((" %s "):format(BRANCH_ICON))
    - (pr and vim.fn.strdisplaywidth(pr) + 2 or 0)
  local ref = cells.clip(summary.ref, room)
  local remote = ref:match("^origin/") or ""
  return table.concat({
    ("%%#%s# %s "):format(M.HEADER_ICON_HL, BRANCH_ICON),
    ("%%#%s#%s"):format(M.HEADER_DIM_HL, remote),
    ("%%#%s#%s"):format(M.HEADER_REF_HL, escaped(ref:sub(#remote + 1))),
    ("%%#%s#%%="):format(M.HEADER_HL),
    pr and ("%%#%s#%s "):format(M.HEADER_DIM_HL, pr) or "",
  })
end

---`N noun`, the glyph and noun dimmed so the number leads.
---@param glyph string
---@param count integer
---@param noun string Singular.
---@return table[] chunks
local function counted(glyph, count, noun)
  return {
    { glyph .. " ", M.HEADER_DIM_HL },
    { tostring(count), M.HEADER_HL },
    { " " .. noun .. (count == 1 and "" or "s"), M.HEADER_DIM_HL },
  }
end

---The header's second row, as a virtual line over the tree: the file count on the
---left, the commits and line totals at the right edge — the totals flush with it, in
---the column every row's own stat already occupies.
---
---Symbols still being read take the file count's place and push the commits out, since
---the counts are about to change under the reader anyway and the width is not there.
---@param summary changeset.Summary
---@param width integer Cells the line spans; padded to fill, so the strip runs the full width.
---@return table[] chunks Virtual-text chunks for one line of `virt_lines`.
function M.header_totals(summary, width)
  local strip = M.HEADER_HL
  local left, right
  if summary.reading then
    left = {
      { ("⋯ reading symbols %d/%d"):format(summary.reading.done, summary.reading.total), { strip, M.META_HL } },
    }
    right = {}
  else
    left = counted(FILES_ICON, summary.files, "file")
    right = (summary.commits or 0) > 0 and counted(COMMIT_ICON, summary.commits, "commit") or {}
  end
  if #right > 0 then
    right[#right + 1] = { "  ", strip }
  end
  vim.list_extend(right, {
    { "+" .. summary.added, { strip, "GitSignsAdd" } },
    { " ", strip },
    { "-" .. summary.removed, { strip, "GitSignsDelete" } },
    -- Over the rows' state gutter, so the totals end in the column their stats do.
    { (" "):rep(GUTTER), strip },
  })

  local chunks = vim.list_extend({ { " ", strip } }, left)
  chunks[#chunks + 1] = { (" "):rep(math.max(width - cells.chunks(chunks) - cells.chunks(right), 1)), strip }
  return vim.list_extend(chunks, right)
end

---The sidebar's statusline. With 'laststatus' at 3 a window's own statusline is drawn
---only while that window has focus, which is exactly when its keys are worth naming.
---@param info changeset.Footer
---@return string
function M.footer(info)
  local parts = { ("%%#%s# Changeset "):format(M.BADGE_HL) }
  if info.file then
    parts[#parts + 1] = ("%%#%s# file %d of %d"):format(M.FOOTER_HL, info.file, info.files)
  end
  if info.query ~= "" then
    parts[#parts + 1] = ("%%#%s#  %s %%#%s#%s"):format(M.FOOTER_HL, FILTER_ICON, M.FOOTER_KEY_HL, escaped(info.query))
  end
  local hints = vim
    .iter(HINTS)
    :filter(function(hint)
      return info.keys[hint[1]]
    end)
    :map(function(hint)
      return ("%%#%s#%s %%#%s#%s"):format(M.FOOTER_KEY_HL, escaped(info.keys[hint[1]]), M.FOOTER_HL, hint[2])
    end)
    :totable()
  -- `%<` before the hints: a bar too narrow for everything gives up the keys first.
  parts[#parts + 1] = ("%%#%s#%%=%%<"):format(M.FOOTER_HL) .. table.concat(hints, "  ") .. " "
  return table.concat(parts)
end

---The winbar over a window the sidebar is borrowing: a band across the top
---saying the file under it is on loan, and which one it is.
---
---Reversed badge, then the file's own icon and path, then where the jump key would
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
    ("%%#%s#%s "):format(M.PREVIEW_HINT_HL, escaped(band.destination or (band.jump and HINT:format(band.jump) or ""))),
  })
end

---Whether `winbar` is a band `preview_winbar` made.
---@param winbar string
---@return boolean
function M.is_preview_winbar(winbar)
  return winbar:find(("%%#%s# Preview "):format(M.PREVIEW_LABEL_HL), 1, true) ~= nil
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

return M
