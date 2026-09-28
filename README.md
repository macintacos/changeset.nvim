# changeset

A read-only sidebar mapping what this branch changed, nested by symbol.

`:Changeset` opens the *map* of what this branch changed. With `pr_review.enabled` set, the
*gutter* marks the same range in PR Review Mode, and `:Changeset review` switches it off or
back on for the branch. Neither drives the other. `require("changeset.pick").pick()`
searches the same changes in a picker once mini.pick is set up, as does `:Pick changeset`
when mini.pick was set up at startup.

In an editor too narrow to leave the files `layout.min_file_width` columns (80 by default)
beside it, the sidebar opens as a drawer along the bottom instead, and moves between the
two as the editor is resized.

## What it shows

Files changed between `merge-base(origin/<default>, HEAD)` — the local default branch
when there is no `origin/` copy of it — and the working tree: the same range PR Review
Mode's gutter marks. On a branch whose open PR targets another branch, that branch stands
in for the default once `gh` names it, and the tree rebuilds onto it. Untracked files
count. A deleted file is listed, but its row previews a notice in place of the file and
never opens it.

Under each file sit the symbols a hunk actually touched, plus the ancestors needed to
place them. Unchanged siblings are hidden: the tree is a map of the diff, not an outline.

Files sit under Implementation / Tests / Docs / Config / Generated headers, in that order,
with Generated folded at first, and are grouped by directory within their section, a
directory's own files ahead of its subdirectories'.

```text
󰴉  Implementation      2 files      +12 -3
▎ 󰛦 session.ts                       +12 -3
  ├─󰌗 SessionStore › refresh › deadline  +8 -1
  ├─󰏿 SESSION_TTL                     +1 -0
  └─󰘦 Other changes                   +3 -2
▎ 󰛦 auth.ts (legacy) deleted

󱁿  Config              1 file        +2 -0
▎ 󰛡 Makefile                          +2 -0
  └─󰘦 Other changes                   +2 -0
```

## Requirements

- Neovim 0.12+ and `git`.

Optional, each adding one thing:

- `gh`: a branch whose open PR targets another branch is compared against
  that branch.
- A language server answering `textDocument/documentSymbol`: the symbol
  rows under each file. Without one, a file lists only its changes.
- The `rust`, `typescript` and `tsx` treesitter parsers: inline test
  symbols are also recognised by their syntax (`#[test]`, `#[cfg(test)]`,
  `import.meta.vitest`), not only by their name.
- mini.icons, set up, or nvim-web-devicons: icons. nvim-web-devicons
  covers files only.
- which-key: `?` opens its popup instead of a float.
- mini.pick: the picker.
- gitsigns: required by PR Review Mode; also colours the status rail
  beside each file.

## Installation

With `vim.pack`:

```lua
vim.pack.add({ "https://github.com/macintacos/changeset.nvim" })
```

With lazy.nvim:

```lua
{ "macintacos/changeset.nvim" }
```

Options go in the spec as `opts = { … }`, which makes lazy.nvim call `setup()` with them.

`setup()` is optional; without it the sidebar works with the defaults below.

## Usage

- `:Changeset` or `:Changeset toggle` opens the sidebar, focuses it, or
  closes it.
- `:Changeset refresh` rebuilds it.
- `:Changeset review` toggles PR Review Mode for the current branch; it
  errors unless `pr_review.enabled` is set.
- `<Plug>(changeset-toggle)` does what `:Changeset toggle` does: closed →
  open and focus the row you are on; open and unfocused → focus the row
  you are on; focused → close and restore focus.

The plugin maps nothing outside the sidebar. A suggested setup:

```lua
vim.keymap.set("n", "<leader>gp", "<Plug>(changeset-toggle)", { desc = "Toggle the changeset sidebar" })
-- :Changeset review needs pr_review.enabled = true
vim.keymap.set("n", "<leader>gP", "<Cmd>Changeset review<CR>", { desc = "Toggle PR Review Mode" })
require("changeset").setup({ keymaps = { next = "]h", prev = "[h" } })
```

## Options

Pass any of these to `require("changeset").setup()` as nested tables
(`{ keymaps = { jump = "o" } }`). Any `keymaps` entry may be `false` to leave it unbound.

<!-- The separator rows' dash counts set the vimdoc's column widths; keep their ratios. -->

| Option | Default | Description |
| --------- | --- | --------------- |
| `keymaps.jump` | `<CR>` | Go to this change |
| `keymaps.jump_close` | `<S-CR>` | Go to this change and close the sidebar |
| `keymaps.jump_vsplit` | `/` | Go to this change in a vertical split |
| `keymaps.jump_split` | `-` | Go to this change in a split |
| `keymaps.jump_tab` | `<C-t>` | Go to this change in a new tab |
| `keymaps.close` | `q` | Close the sidebar |
| `keymaps.expand` | `l` | Expand |
| `keymaps.collapse` | `h` | Collapse, or step out to the parent |
| `keymaps.collapse_all` | `H` | Collapse every file |
| `keymaps.expand_all` | `L` | Expand every file |
| `keymaps.next_section` | `]]` | Next section header |
| `keymaps.prev_section` | `[[` | Previous section header |
| `keymaps.refresh` | `R` | Rebuild the tree |
| `keymaps.yank` | `y` | Yank `path:line` |
| `keymaps.help` | `?` | List the sidebar's keys |
| `keymaps.filter_kinds` | `F` | Open the symbol-kind menu |
| `keymaps.filter` | `f` | Filter the tree |
| `keymaps.next` | `false` | Next change, from any window |
| `keymaps.prev` | `false` | Previous change, from any window |
| `layout.min_file_width` | `80` | Narrowest the files get beside the sidebar before it moves below them |
| `pr_review.enabled` | `false` | PR Review Mode on every branch but the default |

`keymaps.next` and `keymaps.prev` are off by default. When set, they are bound globally
only while the sidebar is open, and what they replaced is restored when it closes.

Each `setup()` call starts again from the defaults, not from the previous call, and
reaches the sidebar the next time it opens. An invalid value is an error naming the
option, and the previous configuration stays in force. Turning `pr_review.enabled` back
off takes a restart.

## Sidebar keys

Moving through the tree previews each change in the window you were last in, under a
band; `<CR>` (or a split or tab key) opens it there for real. Keys shown are the
defaults; each sidebar key is renamed by the `keymaps` option in its row of
[Options](#options).

| Key | Where | Does |
| --- | --- | ------------ |
| `j` / `k` | sidebar | move, previewing into the window you were last in, without leaving the sidebar |
| `<CR>` | sidebar | open it there: focus that window at the row's position, keeping the jump; nothing on a section header |
| `<S-CR>` | sidebar | open it, then close the sidebar behind you |
| `q` | sidebar | close, restore focus and restore the windows it previewed into |
| `h` / `l` | sidebar | collapse / expand; on a header, fold / unfold its section; `h` with nothing left to shut steps out to the parent, so repeated `h` walks up to the filename and then its section header; `l` on a compressed chain expands it to full nesting |
| `H` / `L` | sidebar | collapse / expand every file, the whole-tree form of `h` / `l`; never folds or unfolds a section |
| `]]` / `[[` | sidebar | move to the next / previous section header, a folded one included; stays put when there is none that way |
| `F` | sidebar | open the symbol-kind menu |
| `x` | kind menu | hide or show the kind under the cursor, redrawing the tree at once |
| `<CR>` / `r` / `b` | kind menu | remember this set everywhere / for this repository / for this branch, then close |
| `q` / `<Esc>` | kind menu | close, putting the tree back to the set on disk |
| `f` | sidebar | filter as you type, keeping ancestors so matches stay placed and lighting every match until the filter goes; `<Esc>` restores the last filter |
| `R` | sidebar | rebuild now |
| `y` | sidebar | yank the row's `path:line` to the clipboard; nothing on a section header |
| `/` `-` `<C-t>` | sidebar | open it in a vsplit / split / new tab instead |
| `?` | sidebar | list the keys the sidebar bound, the step keys included when set: which-key's popup where it is installed, a float where it is not |
| `]h` / `[h` | anywhere, while open | off unless set as `keymaps.next` / `keymaps.prev`; advance the sidebar's selection, previewing as it goes and stepping over section headers — review without focusing the sidebar |

Hidden symbol kinds are remembered for this branch, this repository or everywhere; the
narrowest scope with a saved set wins.

## Highlight groups

The sidebar defines these groups as defaults derived from your colorscheme, and
re-derives them on `:colorscheme`.

| Group | Colours | Default |
| --------- | ------------ | ---------- |
| `ChangesetMeta` | Text that is not content: counts, notes | `Comment`'s colour, italic |
| `ChangesetMatch` | Characters a filter matched | links to `Search` |
| `ChangesetHidden` | A kind the tree is not showing, in the kind menu | `Comment`'s colour, struck through |
| `ChangesetHeader` | The sidebar's header strip | `TabLine`'s background |
| `ChangesetHeaderIcon` | The branch glyph on the header | `Directory`'s colour on the header |
| `ChangesetHeaderDim` | The remote, nouns and PR on the header | `Comment`'s colour on the header |
| `ChangesetHeaderRef` | The ref the tree is compared against | `Normal`'s colour on the header, bold |
| `ChangesetBadge` | The badge in the footer | `Directory`'s colour, reversed, bold |
| `ChangesetFooter` | The footer's text | `Comment`'s colour on `StatusLine` |
| `ChangesetFooterKey` | Keys and the filter in the footer | `StatusLine`, bold |
| `ChangesetSelected` | The sidebar's cursor row while focused | `Normal`'s background tinted toward `Statement` |
| `ChangesetHere` | The row for where your cursor is | a lighter `Statement` tint |
| `ChangesetPicked` | The row last opened from the sidebar | a lighter `Statement` tint |
| `ChangesetSelectedIcon` | The glyph on the selected row | `Statement`'s colour |
| `ChangesetHereIcon` | The glyph on the row for where you are | `Statement`'s colour |
| `ChangesetPickedIcon` | The glyph on the row last opened | `Statement`'s colour |
| `ChangesetNoCursor` | The cursor while in the sidebar, hidden | fully blended |
| `ChangesetPreview` | The band over a window being previewed into | `CursorLine`'s background, else `Visual`'s |
| `ChangesetPreviewLabel` | The badge at the head of that band | `DiagnosticWarn`'s colour, reversed, bold |
| `ChangesetPreviewHint` | The hint at the tail of that band | `Comment`'s colour on the band, italic |
| `ChangesetPreviewIcon` | The file's glyph on that band | the file icon's colour on the band |

A colorscheme's definition of a group wins. So does your own `nvim_set_hl`, until the
next `:colorscheme` clears it; to keep an override across colorscheme changes, set it
from a `ColorScheme` autocmd:

```lua
vim.api.nvim_create_autocmd("ColorScheme", {
  callback = function()
    vim.api.nvim_set_hl(0, "ChangesetMatch", { link = "IncSearch" })
  end,
})
```

`ChangesetPreviewIcon` is recoloured for each file, so defining it paints every file's
glyph one colour. The status rail beside each file uses gitsigns' `GitSignsAdd`,
`GitSignsChange`, `GitSignsDelete` and `GitSignsUntracked`.

## PR Review Mode

```lua
require("changeset").setup({ pr_review = { enabled = true } })
```

It needs gitsigns, and uses `gh`, when present, to find an open PR's target branch. It
points gitsigns' gutter at the branch's fork point from the default branch, or from its
open PR's target, so the gutter marks everything the branch changed rather than only
uncommitted work. It stays off on the default branch. `:Changeset review` turns it off
for the current branch, or back on, for the rest of the session. It is independent of
the sidebar: either works without the other.

## Picker

With mini.pick set up, `require("changeset.pick").pick()` searches the same rows as the
sidebar. When mini.pick was set up by the end of startup, `:Pick changeset` does too. A
mini.pick set up later misses that registration; add it yourself:

```lua
MiniPick.registry.changeset = function() return require("changeset.pick").pick() end
```

## Health

`:checkhealth changeset` reports the requirements — Neovim 0.12+ and `git` — and each
optional integration the sidebar quietly does without: `gh` for the PR's target branch,
mini.icons or nvim-web-devicons, which-key, mini.pick, gitsigns (required once
`pr_review.enabled` is set), a language server answering `textDocument/documentSymbol`,
and the `rust`, `typescript` and `tsx` treesitter parsers that mark test symbols. It
then prints the options in force. It checks the way the sidebar loads, so a plugin your
manager has held back may load, but it installs nothing, starts no language server and
asks nothing of the network.

## Where state is stored

- The symbol cache: one JSON file per repository under
  `stdpath("cache")/changeset/`. Safe to delete; the next build is slow
  once.
- Hidden symbol kinds: `stdpath("state")/changeset/filters.json`.
- `:mksession` restores the sidebar when `'sessionoptions'` contains
  `blank` (the default), and its position too when it contains `globals`.
- Folds are kept in memory per repository until Neovim exits.

<!-- panvimdoc-ignore-start -->

Contributors: the design and its rationale are in [docs/design.md](docs/design.md).

<!-- panvimdoc-ignore-end -->
