---The `Changeset*` highlight groups every surface draws with, and the defaults that define them.

local M = {}

-- The highlight groups. Each is only a default: a colorscheme's or the user's own
-- definition of one wins, whenever it is made.

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

---Group for the branch glyph at the head of that strip. Created by `define_highlights`.
---@type string
M.HEADER_ICON_HL = "ChangesetHeaderIcon"

---Group for what is not content on that strip: a remote, a noun, the PR. Created by `define_highlights`.
---@type string
M.HEADER_DIM_HL = "ChangesetHeaderDim"

---Group for the ref the tree is compared against. Created by `define_highlights`.
---@type string
M.HEADER_REF_HL = "ChangesetHeaderRef"

---Group for a review comment's circle and the line numbers it covers in its file. Created by `define_highlights`.
---@type string
M.REVIEW_COMMENT_HL = "ChangesetReviewComment"

---Group for a draft review comment's circle, bubble and line numbers. Created by `define_highlights`.
---@type string
M.REVIEW_COMMENT_DRAFT_HL = "ChangesetReviewCommentDraft"

---A review comment's circle, and a draft's, dotted as not yet saved.
M.REVIEW_COMMENT_CIRCLE = "●"
M.REVIEW_COMMENT_DRAFT_CIRCLE = "◌"

---A review comment's bubble in the sign column, and a draft's: the outline of the same note, not yet filled in.
M.REVIEW_COMMENT_BUBBLE = "󰍩"
M.REVIEW_COMMENT_DRAFT_BUBBLE = "󰍪"

---The review comment's group, or the draft group for a draft.
---@param comment { draft: true? }
---@return string
function M.review_comment_hl(comment)
  return comment.draft and M.REVIEW_COMMENT_DRAFT_HL or M.REVIEW_COMMENT_HL
end

---Group for a review comment's body at the end of its first line. Created by `define_highlights`.
---@type string
M.REVIEW_COMMENT_BODY_HL = "ChangesetReviewCommentBody"

---Group for the border of a review comment's block in its file. Created by `define_highlights`.
---@type string
M.BLOCK_BORDER_HL = "ChangesetBlockBorder"

---Group for the title in a review comment block's border. Created by `define_highlights`.
---@type string
M.BLOCK_TITLE_HL = "ChangesetBlockTitle"

---Group for a review comment block's text. Created by `define_highlights`.
---@type string
M.BLOCK_BODY_HL = "ChangesetBlockBody"

---Group for the border and title of the block the cursor is parked on. Created by `define_highlights`.
---@type string
M.BLOCK_PARKED_HL = "ChangesetBlockParked"

---Group for a draft review comment block's border and title. Created by `define_highlights`.
---@type string
M.BLOCK_DRAFT_HL = "ChangesetBlockDraft"

---Group for the title of the block the cursor is parked on. Created by `define_highlights`.
---@type string
M.BLOCK_PARKED_TITLE_HL = "ChangesetBlockParkedTitle"

---Group for the keys a parked block names in its bottom border. Created by `define_highlights`.
---@type string
M.BLOCK_HINT_HL = "ChangesetBlockHint"

---Group for the badge naming the sidebar in its footer. Created by `define_highlights`.
---@type string
M.BADGE_HL = "ChangesetBadge"

---Group for the footer's text. Created by `define_highlights`.
---@type string
M.FOOTER_HL = "ChangesetFooter"

---Group for the keys and the filter the footer names. Created by `define_highlights`.
---@type string
M.FOOTER_KEY_HL = "ChangesetFooterKey"

---Background of the row the sidebar's cursor is on, while it has focus. Created by `define_highlights`.
---@type string
M.SELECTED_HL = "ChangesetSelected"

---Background of the row for the file and line the cursor is in. Created by `define_highlights`.
---@type string
M.HERE_HL = "ChangesetHere"

---Background of the row last opened from the sidebar. Created by `define_highlights`.
---@type string
M.PICKED_HL = "ChangesetPicked"

---Group for the selected row's glyph. Created by `define_highlights`.
---@type string
M.SELECTED_ICON_HL = "ChangesetSelectedIcon"

---Group for the glyph on the row for where you are. Created by `define_highlights`.
---@type string
M.HERE_ICON_HL = "ChangesetHereIcon"

---Group for the glyph on the row last opened from the sidebar. Created by `define_highlights`.
---@type string
M.PICKED_ICON_HL = "ChangesetPickedIcon"

---Group 'guicursor' draws the cursor in while it is in the sidebar. Created by `define_highlights`.
---@type string
M.NO_CURSOR_HL = "ChangesetNoCursor"

---Group for a dialog's button. Created by `define_highlights`.
---@type string
M.BUTTON_HL = "ChangesetButton"

---Group for a dialog's focused button. Created by `define_highlights`.
---@type string
M.BUTTON_FOCUS_HL = "ChangesetButtonFocus"

---Group for a dialog's destructive button. Created by `define_highlights`.
---@type string
M.BUTTON_DANGER_HL = "ChangesetButtonDanger"

---Group for a dialog's destructive button while focused. Created by `define_highlights`.
---@type string
M.BUTTON_DANGER_FOCUS_HL = "ChangesetButtonDangerFocus"

---Group for a key the review comment window's footer names, drawn as a keycap. Created by `define_highlights`.
---@type string
M.KEYCAP_HL = "ChangesetKeycap"

---Group laid over the letter that presses a dialog's button. Created by `define_highlights`.
---@type string
M.BUTTON_KEY_HL = "ChangesetButtonKey"

---Background of a dialog's focused row. Created by `define_highlights`.
---@type string
M.DIALOG_SELECTED_HL = "ChangesetDialogSelected"

---Background of a line the unified diff shows added. Created by `define_highlights`.
---@type string
M.DIFF_ADD_HL = "ChangesetDiffAdd"

---Background of the words a line the unified diff shows added changed. Created by `define_highlights`.
---@type string
M.DIFF_ADD_TEXT_HL = "ChangesetDiffAddText"

---Background of a line the unified diff shows deleted. Created by `define_highlights`.
---@type string
M.DIFF_DELETE_HL = "ChangesetDiffDelete"

---Background of the words a line the unified diff shows deleted changed. Created by `define_highlights`.
---@type string
M.DIFF_DELETE_TEXT_HL = "ChangesetDiffDeleteText"

---Group for the filetype glyph on the preview band. Recoloured by `band_icon` for each
---file; defining it yourself draws every file's glyph in one colour.
---@type string
M.PREVIEW_ICON_HL = "ChangesetPreviewIcon"

---Group for the file's glyph heading a whole file's review comment window. Recoloured by `title_icon` for each
---window; defining it yourself draws every file's glyph in one colour.
---@type string
M.TITLE_ICON_HL = "ChangesetTitleIcon"

---The sign-column bar a borrowed window draws over its preview's span, in the selection's accent. The two tint groups
---are the bar's copies over an added line's tint, recoloured as `band_icon` recolours the file's glyph.
---@type string
M.PREVIEW_BAR_HL = "ChangesetPreviewBar"
---@type string
M.PREVIEW_BAR_TINT_HL = "ChangesetPreviewBarTint"
---@type string
M.PREVIEW_BAR_ICON_TINT_HL = "ChangesetPreviewBarIconTint"

-- How far each state's background moves from the window's toward the accent.
local SELECTED_TINT, HERE_TINT, PICKED_TINT = 0.2, 0.12, 0.06

-- How far a dialog's button moves from the float's background toward its text, when it can't take the editor's.
local BUTTON_SHADE = 0.15

-- How far a unified diff line's background moves toward its added or deleted colour, and a changed word's.
local DIFF_TINT, DIFF_TEXT_TINT = 0.1, 0.3

---What `set_default` last gave each group, as `definition` read it back.
---@type table<string, vim.api.keyset.get_hl_info>
local last_given = {}

---`name`'s definition without its `default` flag, which setting `Normal` strips from
---every group.
---@param name string
---@return vim.api.keyset.get_hl_info
local function definition(name)
  local hl = vim.api.nvim_get_hl(0, { name = name })
  hl.default = nil
  return hl
end

---Give `name` the default `attrs` unless a colorscheme or the user has defined it. A
---group still holding what this module last gave it is forced over: `default` alone
---would keep the old theme's colours.
---@param name string
---@param attrs vim.api.keyset.highlight
local function set_default(name, attrs)
  local current = definition(name)
  if not vim.tbl_isempty(current) and not vim.deep_equal(current, last_given[name]) then
    return
  end
  vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", attrs, { default = true, force = true }))
  last_given[name] = definition(name)
end

---Point `PREVIEW_ICON_HL` at `hl`'s colour over the band's background.
---
---An icon plugin's group carries a foreground only, so a glyph drawn straight in one
---punches the window's own background through the band. One group recoloured per
---preview rather than one per filetype: only ever one band is on screen.
---@type string? The group the band's glyph last came with, so a new colorscheme can
---be followed: this one is mixed from two resolved colours rather than linked to them.
local band_hl

---@param name string
---@param hl string
---@param under string
---@return string name
local function glyph_over(name, hl, under)
  set_default(name, {
    fg = vim.api.nvim_get_hl(0, { name = hl, link = false }).fg,
    bg = vim.api.nvim_get_hl(0, { name = under, link = false }).bg,
  })
  return name
end

---@param hl string Group the glyph came with.
---@return string group
function M.band_icon(hl)
  band_hl = hl
  return glyph_over(M.PREVIEW_ICON_HL, hl, M.PREVIEW_HL)
end

---Point `name` at `hl`'s colour over an added line's tint, the background the unified diff gives the sign cell it covers.
---A glyph drawn over that cover keeps the tint behind it, as `band_icon` keeps the band's behind a glyph.
---@param name string
---@param hl string Group the glyph came with.
---@return string name
function M.tinted(name, hl)
  return glyph_over(name, hl, M.DIFF_ADD_HL)
end

---The group a review comment window's title glyph last came with, followed as `band_hl` is.
---@type string?
local title_hl

---Point `TITLE_ICON_HL` at `hl`'s colour over `FloatTitle`'s background, as `band_icon` does for the band. One group
---for every window: focus leaving one closes it, so only one is ever open.
---@param hl string Group the glyph came with.
---@return string group
function M.title_icon(hl)
  title_hl = hl
  return glyph_over(M.TITLE_ICON_HL, hl, "FloatTitle")
end

---`amount` of the way from `from` to `to`, channel by channel.
---@param from integer
---@param to integer
---@param amount number
---@return integer
local function mix(from, to, amount)
  local out = 0
  for _, place in ipairs({ 0x10000, 0x100, 1 }) do
    local a, b = math.floor(from / place) % 256, math.floor(to / place) % 256
    out = out + math.floor(a + (b - a) * amount + 0.5) * place
  end
  return out
end

---Create the groups the sidebar draws with, as overridable defaults. `META_HL` is mixed
---from `Comment` rather than linked to it, which would drop the italics.
function M.define_highlights()
  local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
  set_default(M.META_HL, { fg = comment.fg, italic = true })

  -- CursorLine's background is the faintest tint every colorscheme gives a window
  -- to say "this is the thing you are on", so the band reads in any theme without
  -- competing with the file under it. Visual is the same idea two shades louder,
  -- and stands in for a theme that leaves CursorLine to the number column.
  local cursorline = vim.api.nvim_get_hl(0, { name = "CursorLine", link = false })
  local visual = vim.api.nvim_get_hl(0, { name = "Visual", link = false })
  local band = cursorline.bg or visual.bg
  local warn = vim.api.nvim_get_hl(0, { name = "DiagnosticWarn", link = false })
  set_default(M.PREVIEW_HL, { bg = band })
  -- `reverse` rather than a background read off `Normal`: it pairs the accent
  -- with whatever the window is actually drawn on, so the badge survives a
  -- theme that leaves `Normal` transparent.
  set_default(M.PREVIEW_LABEL_HL, { fg = warn.fg or comment.fg, reverse = true, bold = true })
  set_default(M.PREVIEW_HINT_HL, { fg = comment.fg, bg = band, italic = true })
  -- TabLine's background is what a colorscheme paints its own chrome with, so the
  -- header reads as the panel's frame rather than as a preview band.
  local chrome = vim.api.nvim_get_hl(0, { name = "TabLine", link = false }).bg or band
  set_default(M.HEADER_HL, { bg = chrome })
  -- Directory's colour rather than the preview badge's warning yellow: these say
  -- what the panel is, and yellow is already spoken for by "on loan".
  local directory = vim.api.nvim_get_hl(0, { name = "Directory", link = false }).fg or comment.fg
  set_default(M.HEADER_ICON_HL, { fg = directory, bg = chrome })
  set_default(M.HEADER_DIM_HL, { fg = comment.fg, bg = chrome })
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  set_default(M.HEADER_REF_HL, { fg = normal.fg, bg = chrome, bold = true })
  -- The config has no "all is well" green, and GitSignsAdd already means added lines.
  local ok = vim.api.nvim_get_hl(0, { name = "DiagnosticOk", link = false }).fg
  set_default(M.REVIEW_COMMENT_HL, { fg = ok, bold = true })
  -- The saved green faded halfway to Comment and unbolded: the same note, not yet committed to.
  set_default(M.REVIEW_COMMENT_DRAFT_HL, { fg = ok and comment.fg and mix(ok, comment.fg, 0.5) or ok or comment.fg })
  set_default(M.REVIEW_COMMENT_BODY_HL, { link = M.META_HL })
  set_default(M.BADGE_HL, { fg = directory, reverse = true, bold = true })
  local statusline = vim.api.nvim_get_hl(0, { name = "StatusLine", link = false })
  set_default(M.FOOTER_HL, { fg = comment.fg, bg = statusline.bg })
  set_default(M.FOOTER_KEY_HL, { fg = statusline.fg, bg = statusline.bg, bold = true })
  -- What the editor already paints over the text you searched for.
  set_default(M.MATCH_HL, { link = "Search" })
  -- Struck through as well as dimmed: dim on its own is what ancestor rows mean,
  -- and it reads as faint rather than as switched off in a light colourscheme.
  set_default(M.HIDDEN_HL, { fg = comment.fg, strikethrough = true })
  -- Every state tints toward the theme's keyword colour, a hue nothing else on a row
  -- carries, so a tinted row reads as a state rather than as another diff colour.
  -- Mixed rather than linked: an opaque background keeps each token's own colour
  -- legible on top. Over the chrome's background when Normal is transparent.
  local accent = vim.api.nvim_get_hl(0, { name = "Statement", link = false }).fg or normal.fg or 0x808080
  local base = normal.bg or chrome or 0
  set_default(M.SELECTED_HL, { bg = mix(base, accent, SELECTED_TINT) })
  set_default(M.HERE_HL, { bg = mix(base, accent, HERE_TINT) })
  set_default(M.PICKED_HL, { bg = mix(base, accent, PICKED_TINT) })
  set_default(M.SELECTED_ICON_HL, { fg = accent })
  set_default(M.HERE_ICON_HL, { fg = accent })
  set_default(M.PICKED_ICON_HL, { fg = accent })
  set_default(M.PREVIEW_BAR_HL, { fg = accent })
  -- Backgrounds alone, as GitHub draws a diff, so syntax keeps colouring the text. Added and Removed stand in until
  -- gitsigns, which derives its groups from them, has run.
  local added = vim.api.nvim_get_hl(0, { name = "GitSignsAdd", link = false }).fg
    or vim.api.nvim_get_hl(0, { name = "Added", link = false }).fg
  local deleted = vim.api.nvim_get_hl(0, { name = "GitSignsDelete", link = false }).fg
    or vim.api.nvim_get_hl(0, { name = "Removed", link = false }).fg
  set_default(M.DIFF_ADD_HL, { bg = added and mix(base, added, DIFF_TINT) })
  set_default(M.DIFF_ADD_TEXT_HL, { bg = added and mix(base, added, DIFF_TEXT_TINT) })
  set_default(M.DIFF_DELETE_HL, { bg = deleted and mix(base, deleted, DIFF_TINT) })
  set_default(M.DIFF_DELETE_TEXT_HL, { bg = deleted and mix(base, deleted, DIFF_TEXT_TINT) })
  -- A dialog sits on NormalFloat, which no theme checked paints like Normal, so its tints start from the float.
  local float = vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false })
  local float_bg, float_fg = float.bg or base, float.fg or normal.fg or 0x808080
  -- A button is cut from the editor's surface, where the theme keeps its text and its error colour legible. A
  -- float drawn on that surface, or on a transparent one, is shaded toward its text instead.
  local surface = normal.bg ~= nil and normal.bg ~= float_bg
  local pill = surface and normal.bg or mix(float_bg, float_fg, BUTTON_SHADE)
  local danger = vim.api.nvim_get_hl(0, { name = "DiagnosticError", link = false }).fg
  set_default(M.BUTTON_HL, { fg = surface and normal.fg or float_fg, bg = pill })
  set_default(M.BUTTON_DANGER_HL, { fg = danger, bg = pill })
  -- Reversed, as the badges are, so no background is read off a theme that may leave it transparent.
  set_default(M.BUTTON_FOCUS_HL, { fg = accent, reverse = true, bold = true })
  set_default(M.BUTTON_DANGER_FOCUS_HL, { fg = danger, reverse = true, bold = true })
  set_default(M.BUTTON_KEY_HL, { underline = true })
  -- A dialog's button already reads as something to press, on a float's border as in its body.
  set_default(M.KEYCAP_HL, { link = M.BUTTON_HL })
  set_default(M.DIALOG_SELECTED_HL, { bg = mix(float_bg, accent, SELECTED_TINT) })
  -- A block is the review comment window collapsed, so it wears the float's colours.
  set_default(M.BLOCK_BORDER_HL, { link = "FloatBorder" })
  -- Virtual lines sit on Normal, not NormalFloat, so the title takes the float's background or it shows as a hole.
  local float_title = vim.api.nvim_get_hl(0, { name = "FloatTitle", link = false })
  set_default(M.BLOCK_TITLE_HL, { fg = float_title.fg, bg = float.bg, bold = true })
  set_default(M.BLOCK_BODY_HL, { link = "NormalFloat" })
  -- Parked takes the comment marks' green, which no border uses, and a reversed title: it must read on a theme whose
  -- floats have no background to tint.
  -- The draft marks' colour, on the float's background as the other border chunks are.
  local draft = vim.api.nvim_get_hl(0, { name = M.REVIEW_COMMENT_DRAFT_HL, link = false })
  set_default(M.BLOCK_DRAFT_HL, { fg = draft.fg, bg = float.bg })
  set_default(M.BLOCK_PARKED_HL, { fg = ok, bg = float.bg, bold = true })
  set_default(M.BLOCK_PARKED_TITLE_HL, { fg = ok, reverse = true, bold = true })
  set_default(M.BLOCK_HINT_HL, { fg = comment.fg, bg = float.bg, italic = true })
  -- Fully blended is the TUI's cue to hide the cursor outright. `nocombine` is only
  -- there to keep the group: one holding nothing but `blend` is stored as cleared.
  set_default(M.NO_CURSOR_HL, { blend = 100, nocombine = true })
  -- Last, over the band it is drawn on: a glyph left on the old theme's colour is
  -- the one thing here that can come out invisible rather than merely off-key.
  if band_hl then
    M.band_icon(band_hl)
  end
  if title_hl then
    M.title_icon(title_hl)
  end
end

M.define_highlights()

-- The meta highlight is mixed from Comment's foreground, which a new colorscheme replaces. Here, where every surface
-- takes its groups, since a review verb loads without the sidebar.
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("changeset.highlights", { clear = true }),
  desc = "changeset: rebuild the highlight groups against the new palette",
  callback = M.define_highlights,
})

return M
