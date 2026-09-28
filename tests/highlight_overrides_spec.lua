-- Before anything in the plugin loads, as a user's config would.
vim.api.nvim_set_hl(0, "ChangesetHeaderRef", { fg = 0x0a0b0c })

local render = require("changeset.render")
require("changeset") -- registers the ColorScheme autocmd

local colors = vim.fn.tempname()
vim.fn.mkdir(colors .. "/colors", "p")
vim.opt.rtp:append(colors)

---Write `colors/<name>.lua` from `lines` and switch to it.
---@param name string
---@param lines string[]
local function colorscheme(name, lines)
  vim.fn.writefile(lines, ("%s/colors/%s.lua"):format(colors, name))
  vim.cmd.colorscheme(name)
end

---@param name string
---@return vim.api.keyset.get_hl_info
local function group(name)
  return vim.api.nvim_get_hl(0, { name = name, link = false })
end

describe("highlight overrides", function()
  it("keeps a group the user defined before the plugin loaded", function()
    render.define_highlights()

    assert.equal(0x0a0b0c, group("ChangesetHeaderRef").fg)
    assert.is_true(group(render.META_HL).italic)
  end)

  it("recomputes the derived colours on each colorscheme switch, even without hi clear", function()
    colorscheme("one", {
      'vim.cmd.highlight("clear")',
      'vim.g.colors_name = "one"',
      'vim.api.nvim_set_hl(0, "Comment", { fg = 0x111111 })',
    })
    assert.equal(0x111111, group(render.META_HL).fg)

    colorscheme("two", {
      'vim.g.colors_name = "two"',
      'vim.api.nvim_set_hl(0, "Comment", { fg = 0x222222 })',
    })
    assert.equal(0x222222, group(render.META_HL).fg)
  end)

  it("keeps a group the colorscheme defines", function()
    colorscheme("three", {
      'vim.cmd.highlight("clear")',
      'vim.g.colors_name = "three"',
      'vim.api.nvim_set_hl(0, "Comment", { fg = 0x444444 })',
      'vim.api.nvim_set_hl(0, "ChangesetMeta", { fg = 0x333333 })',
    })

    assert.equal(0x333333, group(render.META_HL).fg)
    assert.is_nil(group(render.META_HL).italic)
    assert.equal(0x444444, group(render.HIDDEN_HL).fg)
  end)

  it("recolours the band's glyph for each file previewed", function()
    vim.api.nvim_set_hl(0, "ChangesetSpecGlyphA", { fg = 0xaa0000 })
    vim.api.nvim_set_hl(0, "ChangesetSpecGlyphB", { fg = 0x00bb00 })

    render.band_icon("ChangesetSpecGlyphA")
    render.band_icon("ChangesetSpecGlyphB")

    assert.equal(0x00bb00, group(render.PREVIEW_ICON_HL).fg)
  end)
end)
