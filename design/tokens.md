# Tokens

The plugin's colour roles and the theme groups each is borrowed from. The source of truth
is `define_highlights()` in `lua/changeset/highlights.lua`, which reads the theme on every
`ColorScheme` and gives each `Changeset*` group as an overridable default. The mix ratios
are its named constants (`SELECTED_TINT`, `DIFF_TINT` and the rest), not repeated here.

## Roles

| Role | Borrowed from | Drawn as |
| --- | --- | --- |
| Canvas | `Normal` background; `NormalFloat`'s for floats | The window itself, never painted over |
| Chrome | `TabLine` background, else `CursorLine`'s | `ChangesetHeader` strip |
| Text | `Normal` foreground; `NormalFloat`'s on floats | Rows, `ChangesetHeaderRef`, buttons |
| Secondary text | `Comment` foreground, italic for meta | `ChangesetMeta`, `ChangesetHeaderDim`, `ChangesetFooter`, `ChangesetPreviewHint`, `ChangesetBlockHint`, `ChangesetHidden` |
| Accent | `Statement` foreground | Row-state glyphs, focused button, preview bar |
| Panel accent | `Directory` foreground | Header branch glyph, footer badge |
| On loan | `DiagnosticWarn` foreground | Preview badge |
| Destructive | `DiagnosticError` foreground | Delete button |
| Status | `DiagnosticOk` foreground; a draft mixes it toward `Comment` | Review comment marks and blocks |
| Data | `GitSignsAdd`, `GitSignsChange`, `GitSignsDelete`, else `Added` and `Removed` | Status rail, `+N -N` stats |
| Match | `Search` | `ChangesetMatch` |
| Separator | `FloatBorder` | Block borders |
| Pointer | `DiagnosticInfo` foreground | Only as the hover tint's direction |

## Bands

A band is a background the plugin lays behind text. It takes the theme's own band key
where one fits, and mixes two theme colours only where the theme has none.

| Band | Source |
| --- | --- |
| Preview band | `CursorLine` background, else `Visual`'s |
| Header strip | `TabLine` background |
| Selected, here, picked rows | `Normal` background mixed toward `Statement` |
| Pointer row | `Normal` background mixed toward `DiagnosticInfo` |
| Viewed rows | `Normal` background mixed toward `Comment` |
| Added and deleted lines, changed words | `Normal` background mixed toward `GitSignsAdd` or `GitSignsDelete` |
| Dialog row | `NormalFloat` background mixed toward `Statement` |
| Button pill | `Normal` background where the float's differs, else the float's mixed toward its text |

Where `Normal` is transparent, a mix starts from the chrome's background instead. Mixes
are channel by channel in sRGB (`decisions.md` says why).

## Checked pairings

Where the plugin pairs colours the theme never paired, the pairing is checked against its
floor as the colorscheme loads, and the first candidate that holds wins. Where none holds,
the one that comes closest does. Accepted on 2026-10-24; `highlights.lua` does not apply
it yet.

| Pairing | Floor | Candidates, in order |
| --- | --- | --- |
| Dim text on the header strip | 4.5:1 | `Comment`, then `TabLine`'s own text |
| Dim text on the footer | 4.5:1 | `Comment`, then `StatusLineNC`'s text, then `StatusLine`'s |
| Dim text on a float | 4.5:1 | `Comment`, then `NormalFloat`'s text |
| Branch on the header strip | 4.5:1 | `Normal`'s text, then `TabLineSel`'s, then `TabLine`'s |
| Preview hint on the band | 3:1 | `Comment`, then `Normal`'s text |
| Review comment marks | 4.5:1 | `DiagnosticOk`, then `MoreMsg`, then `Question` |
| Delete button | 4.5:1 | `DiagnosticError`, then `ErrorMsg`, then `Error` |
| Text on an accent fill: badges, focused buttons, the parked title | 4.5:1 | `Normal`'s text or ground, whichever reads |

Every surface is read as drawn: `StatusLine`, `TabLine` and the rest with their `reverse`
applied.
