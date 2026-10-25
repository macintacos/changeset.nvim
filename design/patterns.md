# Patterns

The devices that recur across the sidebar, its floats and its marks. Each links to the
`doc/agents/design.md` section that explains it.

## In use

- **The status rail.** A `▎` in gitsigns' colour leads every file row and is the one bold
  element. (§ The status rail is the one bold element)
- **Three levels of emphasis.** Content in `Normal`, context in `Comment`, meta in
  `Comment` italic. No row is bold. (§ Three levels of emphasis, all theme-derived)
- **Row states as tint and glyph.** Selected `◀`, here `◁` and picked `•` each tint their
  row and mark it in a right-edge gutter, so a state never rests on colour alone. (§ Three
  rows say what is selected, where you are and what you opened)
- **The border labels the float.** A rounded border, its title naming the thing, its
  footer naming where it is kept or the keys that end it. (§ The kind menu docks against
  the sidebar, § Dialogs ask in floats of changeset's own)
- **Keys on the controls.** The footer names four keys, the review comment window's
  footer and a parked block name theirs as keycaps, and a dialog underlines the letter
  that presses each button. `?` lists everything else. A setting that hides them is owed
  (`decisions.md`).
- **Glyphs beside words, from the icon plugin.** File, symbol and section icons come from
  mini.icons or nvim-web-devicons. The few glyphs no icon plugin has, such as the comment
  bubble, are borrowed and listed where they are used. (§ Icons come from an icon plugin)
- **Box-drawing guides.** `├─ └─ │` for the tree, ` › ` to join a compressed chain.
  (§ Tree guides and chain separators are the outline picker's)
- **Middle-dot meta strings.** `3 comments · 1 draft`, `Review comment · line 3`,
  `<CR> edit · d delete`.
- **Compact rows.** One line per row, one blank cell before the first glyph, no indent
  under a section header.

## Refused

- **Eyebrows.** No small label above a heading, here or in any float.
- **Bold rows.** Bold is kept for badges, the focused button and the review comment
  marks.
- **Kind labels.** The icon carries kind; the right edge goes to the stat. (§ Kind labels
  are dropped; the icon carries kind)
