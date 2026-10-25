# Decisions

Newest first. Each records the options compared and what settled the choice.

## 2026-10-24: the palette is borrowed

The palette is derived from the user's colorscheme, never set from the author's own
configuration. Each option below was compared on screens captured from Neovim 0.12.5
running the plugin on a fixture branch with Python, Rust, TypeScript, Lua, fish and TOML
changes, under eight colorschemes. Contrast was then checked across 25 colorscheme
variants: the schemes Neovim bundles, in both backgrounds where they have both, plus
Nordic and Dracula Pro. The A/B page:
https://claude.ai/artifact/Kwjt1wC1Uz9ECRXRLfsjfV

### The selection band keeps its tint toward `Statement`

Compared with the theme's own `CursorLine`. `CursorLine` lifts dimmed rows on the
selection over 3:1 in more themes (16 of 24 against 13), but it nearly vanishes in some.
In Catppuccin Latte it sits 1.8 ΔE_OK from the ground. The sidebar hides its cursor, so a
selection that vanishes loses the cursor with it. The tint stands out in all 22 themes
measured.

### Text on borrowed surfaces is checked as the colorscheme loads

Compared with pairing each colour as written. The fixed pairings fail most where a
light theme or a `reverse` statusline meets them. Footer text held 4.5:1 in 6 of 24
themes, the footer badge in 6 of 20, and the Delete button in 5 of 24. Review comment green fell to
1.25:1 in Catppuccin Latte. Checking each pairing against theme candidates (`tokens.md`
§ Checked pairings) raised those to 13, 14 and 11, and review comments to 17 of 19.
Some pairings still miss where no theme colour holds, such as the preview badge's yellow
in Catppuccin Latte, and the accent is not changed to pass. Not built yet.

### Diff tints stay mixed from the sign colours

Compared with the theme's `DiffAdd` and `DiffDelete` backgrounds. Comments on added lines
held 3:1 in 17 of 22 themes with the mix, against 10 of 22 with the theme's bands, and
`DiffDelete` has no background in Neovim's default, Dracula Pro and three others.

### Tints mix in sRGB

Mixing in OKLab would move the tints a median 0.8 ΔE_OK and at most 3.9, below what
reads. OKLCH's polar form swings their hue (`exceptions.md`).

### Controls name their keys, and hiding them is owed

The keys on the footer, the review comment window and parked blocks are the pattern. A
single setting that hides them all is owed, and not built yet.
