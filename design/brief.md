# Brief

changeset.nvim draws inside someone else's editor, under a colorscheme it didn't choose.
It has no palette of its own. Every colour is borrowed from the user's colorscheme as it
loads, so the sidebar, its floats and its marks read as part of whatever theme the user
runs, dark or light. Its job is to map what a branch changed without competing with the
code the user came to read.

## Rules every surface follows

- **Borrow, never invent.** Each colour is a theme group's colour, or a mix of two theme
  colours where the theme has no band for the job. A hex literal appears only as a
  last-resort fallback for a theme that defines nothing.
- **Borrow pairings, then check them.** Text goes on the surface the theme designed it
  for. Where the plugin pairs colours the theme never paired, such as `Comment` on the
  statusline, it checks the pairing against its floor as the colorscheme loads and falls
  back through theme colours that mean the same thing.
- **Read colours as drawn.** A group with `reverse` is read with its colours swapped, and
  an unset background is the surface's own.
- **Use accents verbatim.** A theme's accent is never lightened or darkened to pass a
  floor. Text on an accent fill takes the theme's own text or ground colour, whichever
  reads on it.
- **One bold element.** The status rail carries change type. Everything else stays quiet.
- **Speak the editor's vocabulary.** gitsigns' groups mean change type, `Search` means a
  match, `CursorLine` means the thing you are on, and icons come from the icon plugin.
- **Keyboard first.** Every control names the key that runs it, and `?` lists the rest.
- **Light and dark alike.** Every derivation is checked against light colorschemes as
  well as dark ones.

## Floors

The shared floors hold for every pairing the plugin makes: text holds 4.5:1 on a surface
and 3:1 on a highlight band, and colour is never the only signal. A pairing the theme
designed itself, such as `Comment` on `Normal`, is the theme's to keep. The plugin never
repaints a theme's text to rescue it, and never weakens a band to suit a theme's faint
comments.
