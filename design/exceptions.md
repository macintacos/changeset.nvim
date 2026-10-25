# Exceptions

Where changeset.nvim departs from the shared taste, and why.

- **Most bands are mixed, not taken from the theme's band keys.** The shared rule takes
  every band from the palette's own keys. Themes have one key for "the thing you are on",
  `CursorLine`, but the sidebar needs three graded row states, a pointer and a viewed
  wash, and `CursorLine` is too faint to stand in for the hidden cursor. `DiffAdd` and
  `DiffDelete` exist but are unreliable behind code: older themes paint them vivid, and
  several give `DiffDelete` no background at all. So those bands mix two theme colours
  (`decisions.md`, 2026-10-24).
- **Bands mix in sRGB, not OKLCH.** The shared rule mixes a missing tint in OKLCH. Mixing
  in OKLab instead of sRGB moves these tints by a median of 0.8 ΔE_OK, below what reads.
  Mixing in OKLCH's polar form swings the hue through colours neither end holds, up to
  13.9 ΔE_OK, as when an added word in a cool-grounded theme tints blue instead of green.
- **A theme's own pairings keep its contrast.** Where a theme's `Comment` misses 3:1 on
  its own ground, as Nordic's does at 2:1, no band can lift it, and the plugin doesn't
  repaint it.
- **The draft colour is a mix.** The shared rule uses accents verbatim. A draft review
  comment fades the saved green halfway to `Comment`: the same note, not yet committed.
  Shape carries the difference (`󰍪`, `◌`), so the colour only backs it up.
- **Faces belong to the terminal.** The shared faces don't apply: the editor draws in the
  user's terminal font. Glyphs assume a Nerd Font.
- **No sound, no motion.** A terminal plugin makes no sound, and Neovim highlights change
  at once.
- **No themes of its own.** Light and dark both come from the user's colorscheme, so
  every derivation is checked against both rather than designed twice.
