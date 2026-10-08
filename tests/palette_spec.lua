-- Before anything in the plugin loads, as a user's config would.
vim.api.nvim_set_hl(0, "ChangesetHeaderRef", { fg = 0x0a0b0c })

local highlights = require("changeset.highlights")
require("changeset") -- registers the ColorScheme autocmd

local runtime_dir = vim.fn.tempname()
vim.fn.mkdir(runtime_dir .. "/colors", "p")
vim.opt.rtp:append(runtime_dir)

---Write `colors/<name>.lua` from `lines` and switch to it.
---@param name string
---@param lines string[]
local function colorscheme(name, lines)
  vim.fn.writefile(lines, ("%s/colors/%s.lua"):format(runtime_dir, name))
  vim.cmd.colorscheme(name)
end

---@param name string
---@return vim.api.keyset.get_hl_info
local function group(name)
  return vim.api.nvim_get_hl(0, { name = name, link = false })
end

describe("highlight overrides", function()
  -- Its colorschemes leave groups behind that `define_highlights` would then keep as theirs.
  after_each(function()
    vim.cmd.highlight("clear")
  end)

  -- First: every later spec switches colorscheme, and `hi clear` wipes the group set above.
  it("keeps a group the user defined before the plugin loaded", function()
    highlights.define_highlights()

    assert.equal(0x0a0b0c, group("ChangesetHeaderRef").fg)
  end)

  it("keeps the match group linked to Search across redefinitions", function()
    highlights.define_highlights()
    highlights.define_highlights()
    assert.equal("Search", vim.api.nvim_get_hl(0, { name = highlights.MATCH_HL }).link)

    colorscheme("zero", { 'vim.cmd.highlight("clear")', 'vim.g.colors_name = "zero"' })
    assert.equal("Search", vim.api.nvim_get_hl(0, { name = highlights.MATCH_HL }).link)
  end)

  it("recomputes the derived colours on each colorscheme switch, even without hi clear", function()
    colorscheme("one", {
      'vim.cmd.highlight("clear")',
      'vim.g.colors_name = "one"',
      'vim.api.nvim_set_hl(0, "Comment", { fg = 0x111111 })',
    })
    assert.equal(0x111111, group(highlights.META_HL).fg)

    colorscheme("two", {
      'vim.g.colors_name = "two"',
      'vim.api.nvim_set_hl(0, "Normal", { fg = 0xcccccc })',
      'vim.api.nvim_set_hl(0, "Comment", { fg = 0x222222 })',
    })
    assert.equal(0x222222, group(highlights.META_HL).fg)
  end)

  it("keeps a group the colorscheme defines", function()
    colorscheme("three", {
      'vim.cmd.highlight("clear")',
      'vim.g.colors_name = "three"',
      'vim.api.nvim_set_hl(0, "Comment", { fg = 0x444444 })',
      'vim.api.nvim_set_hl(0, "ChangesetMeta", { fg = 0x333333 })',
    })

    assert.equal(0x333333, group(highlights.META_HL).fg)
    assert.is_nil(group(highlights.META_HL).italic)
    assert.equal(0x444444, group(highlights.HIDDEN_HL).fg)
  end)

  it("recolours the band's glyph for each file previewed", function()
    vim.api.nvim_set_hl(0, "ChangesetSpecGlyphA", { fg = 0xaa0000 })
    vim.api.nvim_set_hl(0, "ChangesetSpecGlyphB", { fg = 0x00bb00 })

    highlights.band_icon("ChangesetSpecGlyphA")
    highlights.band_icon("ChangesetSpecGlyphB")

    assert.equal(0x00bb00, group(highlights.PREVIEW_ICON_HL).fg)
  end)
end)

describe("define_highlights", function()
  local GROUP_NAMES = {
    "Comment",
    "CursorLine",
    "Visual",
    "DiagnosticWarn",
    "TabLine",
    "Directory",
    "StatusLine",
    "Statement",
    "Normal",
    "DiagnosticOk",
    "NormalFloat",
    "DiagnosticError",
    "GitSignsAdd",
    "GitSignsDelete",
    "Added",
    "Removed",
  }
  local saved

  before_each(function()
    saved = {}
    for _, name in ipairs(GROUP_NAMES) do
      saved[name] = group(name)
    end
    -- `band_hl` is file-local with `band_icon` as its only writer, so without a pin
    -- here each test inherits whichever group the last one happened to set. No getter
    -- to read it back, so unlike the groups above it stays pinned past this block.
    vim.api.nvim_set_hl(0, "ChangesetSpecIcon", { fg = 0x00ff00 })
    highlights.band_icon("ChangesetSpecIcon")
  end)

  after_each(function()
    for _, name in ipairs(GROUP_NAMES) do
      vim.api.nvim_set_hl(0, name, saved[name])
    end
  end)

  it("keeps the previewed file's icon sitting on the band's new colour", function()
    vim.api.nvim_set_hl(0, "CursorLine", { bg = 0x123456 })

    highlights.define_highlights()

    local icon = group(highlights.PREVIEW_ICON_HL)
    assert.equal(0x123456, icon.bg)
    assert.equal(0x00ff00, icon.fg)
  end)

  it("makes the meta group Comment's colour with italics added", function()
    vim.api.nvim_set_hl(0, "Comment", { fg = 0x336699 })

    highlights.define_highlights()

    local meta = group(highlights.META_HL)
    assert.equal(0x336699, meta.fg)
    assert.is_true(meta.italic)
  end)

  it("falls back to Visual for the band in a theme that tints no CursorLine", function()
    vim.api.nvim_set_hl(0, "CursorLine", {})
    vim.api.nvim_set_hl(0, "Visual", { bg = 0xabcdef })

    highlights.define_highlights()

    assert.equal(0xabcdef, group(highlights.PREVIEW_HL).bg)
  end)

  it("paints the preview badge in the theme's warning colour", function()
    vim.api.nvim_set_hl(0, "Comment", { fg = 0x336699 })
    vim.api.nvim_set_hl(0, "DiagnosticWarn", { fg = 0xffaa00 })

    highlights.define_highlights()

    assert.equal(0xffaa00, group(highlights.PREVIEW_LABEL_HL).fg)
  end)

  it("falls back to Comment for the preview badge in a theme with no warning colour", function()
    vim.api.nvim_set_hl(0, "Comment", { fg = 0x336699 })
    vim.api.nvim_set_hl(0, "DiagnosticWarn", {})

    highlights.define_highlights()

    assert.equal(0x336699, group(highlights.PREVIEW_LABEL_HL).fg)
  end)

  it("paints the header with the theme's own chrome, not the band's shade", function()
    vim.api.nvim_set_hl(0, "CursorLine", { bg = 0x123456 })
    vim.api.nvim_set_hl(0, "TabLine", { bg = 0x654321 })

    highlights.define_highlights()

    assert.equal(0x654321, group(highlights.HEADER_HL).bg)
  end)

  it("falls back to the band for the header in a theme that paints no chrome", function()
    vim.api.nvim_set_hl(0, "CursorLine", { bg = 0x123456 })
    vim.api.nvim_set_hl(0, "TabLine", {})

    highlights.define_highlights()

    assert.equal(0x123456, group(highlights.HEADER_HL).bg)
  end)

  it("paints the footer badge in the theme's directory colour", function()
    vim.api.nvim_set_hl(0, "Comment", { fg = 0x336699 })
    vim.api.nvim_set_hl(0, "Directory", { fg = 0x4488cc })

    highlights.define_highlights()

    assert.equal(0x4488cc, group(highlights.BADGE_HL).fg)
  end)

  it("falls back to Comment for the footer badge in a theme with no directory colour", function()
    vim.api.nvim_set_hl(0, "Comment", { fg = 0x336699 })
    vim.api.nvim_set_hl(0, "Directory", {})

    highlights.define_highlights()

    assert.equal(0x336699, group(highlights.BADGE_HL).fg)
  end)

  it("reverses both badges, so neither needs an opaque Normal", function()
    highlights.define_highlights()

    assert.is_true(group(highlights.PREVIEW_LABEL_HL).reverse)
    assert.is_true(group(highlights.BADGE_HL).reverse)
  end)

  it("sets the header's icon, remote and ref on the header's strip", function()
    vim.api.nvim_set_hl(0, "TabLine", { bg = 0x654321 })
    vim.api.nvim_set_hl(0, "Directory", { fg = 0x4488cc })
    vim.api.nvim_set_hl(0, "Comment", { fg = 0x336699 })

    highlights.define_highlights()

    assert.same({ 0x4488cc, 0x654321 }, { group(highlights.HEADER_ICON_HL).fg, group(highlights.HEADER_ICON_HL).bg })
    assert.same({ 0x336699, 0x654321 }, { group(highlights.HEADER_DIM_HL).fg, group(highlights.HEADER_DIM_HL).bg })
    assert.equal(0x654321, group(highlights.HEADER_REF_HL).bg)
    assert.is_true(group(highlights.HEADER_REF_HL).bold)
  end)

  it("paints the footer on the statusline's own background", function()
    vim.api.nvim_set_hl(0, "StatusLine", { fg = 0xeeeeee, bg = 0x222222 })
    vim.api.nvim_set_hl(0, "Comment", { fg = 0x336699 })

    highlights.define_highlights()

    assert.same({ 0x336699, 0x222222 }, { group(highlights.FOOTER_HL).fg, group(highlights.FOOTER_HL).bg })
    assert.same({ 0xeeeeee, 0x222222 }, { group(highlights.FOOTER_KEY_HL).fg, group(highlights.FOOTER_KEY_HL).bg })
  end)

  ---@param color integer
  ---@return integer[] rgb
  local function channels(color)
    return { bit.band(bit.rshift(color, 16), 0xff), bit.band(bit.rshift(color, 8), 0xff), bit.band(color, 0xff) }
  end

  -- A red-only accent over a grey background: a tint of it moves the red channel alone.
  local BACKGROUND, RED = 0x101010, 0xf01010

  it("tints the selected row part of the way from the background to the theme's accent", function()
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xcccccc, bg = BACKGROUND })
    vim.api.nvim_set_hl(0, "Statement", { fg = RED })

    highlights.define_highlights()

    local r, g, b = unpack(channels(group(highlights.SELECTED_HL).bg))
    assert.is_true(r > 0x10 and r < 0xf0)
    assert.same({ 0x10, 0x10 }, { g, b })
  end)

  it("tints the row you are on more faintly than the selected one", function()
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xcccccc, bg = BACKGROUND })
    vim.api.nvim_set_hl(0, "Statement", { fg = RED })

    highlights.define_highlights()

    local here, selected = channels(group(highlights.HERE_HL).bg), channels(group(highlights.SELECTED_HL).bg)
    assert.is_true(here[1] > 0x10 and here[1] < selected[1])
    assert.same({ 0x10, 0x10 }, { here[2], here[3] })
  end)

  it("tints the row you last opened more faintly than the row you are on", function()
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xcccccc, bg = BACKGROUND })
    vim.api.nvim_set_hl(0, "Statement", { fg = RED })

    highlights.define_highlights()

    local picked, here = channels(group(highlights.PICKED_HL).bg), channels(group(highlights.HERE_HL).bg)
    assert.is_true(picked[1] > 0x10 and picked[1] < here[1])
    assert.same({ 0x10, 0x10 }, { picked[2], picked[3] })
  end)

  it("tints over the theme's chrome when Normal is transparent", function()
    vim.api.nvim_set_hl(0, "Statement", { fg = RED })
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xcccccc, bg = BACKGROUND })
    highlights.define_highlights()
    local opaque = group(highlights.SELECTED_HL).bg
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xcccccc })
    vim.api.nvim_set_hl(0, "TabLine", { bg = BACKGROUND })

    highlights.define_highlights()

    assert.equal(opaque, group(highlights.SELECTED_HL).bg)
  end)

  it("tints toward Normal's text in a theme whose Statement has no colour", function()
    vim.api.nvim_set_hl(0, "Normal", { fg = RED, bg = BACKGROUND })
    vim.api.nvim_set_hl(0, "Statement", { bold = true })

    highlights.define_highlights()

    local r, g, b = unpack(channels(group(highlights.SELECTED_HL).bg))
    assert.is_true(r > 0x10 and r < 0xf0)
    assert.same({ 0x10, 0x10 }, { g, b })
  end)

  local GREEN = 0x10f010

  it("tints the unified diff's added lines toward the theme's added colour, a changed word further", function()
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xcccccc, bg = BACKGROUND })
    vim.api.nvim_set_hl(0, "GitSignsAdd", { fg = GREEN })

    highlights.define_highlights()

    local line, word = group(highlights.DIFF_ADD_HL), group(highlights.DIFF_ADD_TEXT_HL)
    local l, w = channels(line.bg), channels(word.bg)
    assert.is_true(l[2] > 0x10 and l[2] < w[2] and w[2] < 0xf0)
    assert.same({ 0x10, 0x10, 0x10, 0x10 }, { l[1], l[3], w[1], w[3] })
    assert.same({}, { line.fg, word.fg })
  end)

  it("tints the unified diff's deleted lines toward the theme's deleted colour, a changed word further", function()
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xcccccc, bg = BACKGROUND })
    vim.api.nvim_set_hl(0, "GitSignsDelete", { fg = RED })

    highlights.define_highlights()

    local line, word = group(highlights.DIFF_DELETE_HL), group(highlights.DIFF_DELETE_TEXT_HL)
    local l, w = channels(line.bg), channels(word.bg)
    assert.is_true(l[1] > 0x10 and l[1] < w[1] and w[1] < 0xf0)
    assert.same({ 0x10, 0x10, 0x10, 0x10 }, { l[2], l[3], w[2], w[3] })
    assert.same({}, { line.fg, word.fg })
  end)

  it("tints the unified diff from Added and Removed before gitsigns has coloured its groups", function()
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xcccccc, bg = BACKGROUND })
    vim.api.nvim_set_hl(0, "GitSignsAdd", {})
    vim.api.nvim_set_hl(0, "GitSignsDelete", {})
    vim.api.nvim_set_hl(0, "Added", { fg = GREEN })
    vim.api.nvim_set_hl(0, "Removed", { fg = RED })

    highlights.define_highlights()

    local added, deleted = channels(group(highlights.DIFF_ADD_HL).bg), channels(group(highlights.DIFF_DELETE_HL).bg)
    assert.is_true(added[2] > 0x10 and deleted[1] > 0x10)
    assert.same({ 0x10, 0x10, 0x10, 0x10 }, { added[1], added[3], deleted[2], deleted[3] })
  end)

  it("draws every state glyph in the accent", function()
    vim.api.nvim_set_hl(0, "Statement", { fg = 0xc8a0f0 })

    highlights.define_highlights()

    assert.same(
      { 0xc8a0f0, 0xc8a0f0, 0xc8a0f0 },
      { group(highlights.SELECTED_ICON_HL).fg, group(highlights.HERE_ICON_HL).fg, group(highlights.PICKED_ICON_HL).fg }
    )
  end)

  it("tints a dialog's focused row over the float's background, not the editor's", function()
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xcccccc, bg = 0xf0f0f0 })
    vim.api.nvim_set_hl(0, "NormalFloat", { fg = 0xcccccc, bg = BACKGROUND })
    vim.api.nvim_set_hl(0, "Statement", { fg = RED })

    highlights.define_highlights()

    local r, g, b = unpack(channels(group(highlights.DIALOG_SELECTED_HL).bg))
    assert.is_true(r > 0x10 and r < 0xf0)
    assert.same({ 0x10, 0x10 }, { g, b })
  end)

  it("cuts a dialog's buttons from the editor's surface, where the theme keeps its text legible", function()
    vim.api.nvim_set_hl(0, "Normal", { fg = 0x111111, bg = 0xf0f0f0 })
    vim.api.nvim_set_hl(0, "NormalFloat", { fg = 0xffffff, bg = 0x000000 })

    highlights.define_highlights()

    assert.same({ 0x111111, 0xf0f0f0 }, { group(highlights.BUTTON_HL).fg, group(highlights.BUTTON_HL).bg })
    assert.equal(0xf0f0f0, group(highlights.BUTTON_DANGER_HL).bg)
  end)

  it("shades a dialog's buttons toward the float's text when the float is the editor's surface", function()
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xcccccc, bg = 0x000000 })
    vim.api.nvim_set_hl(0, "NormalFloat", { fg = 0xffffff, bg = 0x000000 })

    highlights.define_highlights()

    local r, g, b = unpack(channels(group(highlights.BUTTON_HL).bg))
    assert.is_true(r > 0 and r < 0x80)
    assert.same({ r, r }, { g, b })
    assert.equal(0xffffff, group(highlights.BUTTON_HL).fg)
  end)

  it("draws the destructive button in the theme's error colour, reversed while focused", function()
    vim.api.nvim_set_hl(0, "DiagnosticError", { fg = RED })

    highlights.define_highlights()

    assert.equal(RED, group(highlights.BUTTON_DANGER_HL).fg)
    assert.same(
      { RED, true },
      { group(highlights.BUTTON_DANGER_FOCUS_HL).fg, group(highlights.BUTTON_DANGER_FOCUS_HL).reverse }
    )
  end)

  it("draws the focused button reversed in the accent", function()
    vim.api.nvim_set_hl(0, "Statement", { fg = 0xc8a0f0 })

    highlights.define_highlights()

    assert.same({ 0xc8a0f0, true }, { group(highlights.BUTTON_FOCUS_HL).fg, group(highlights.BUTTON_FOCUS_HL).reverse })
  end)

  it("strikes a hidden kind through as well as dimming it", function()
    vim.api.nvim_set_hl(0, "Comment", { fg = 0x336699 })

    highlights.define_highlights()

    local hidden = group(highlights.HIDDEN_HL)
    assert.equal(0x336699, hidden.fg)
    assert.is_true(hidden.strikethrough)
  end)
end)
