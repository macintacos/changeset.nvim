# prtree

A read-only sidebar mapping what this branch changed, nested by symbol.

`<leader>gp` puts the *gutter* in PR Review Mode. `<leader>gP` opens the *map* of the
same range. They are siblings and read the same base, but neither drives the other.

## What it shows

Files changed between `merge-base(origin/<default>, HEAD)` and the working tree — the
same range PR Review Mode's gutter marks, so the sidebar and the signs never disagree.
Untracked files count; deleted files are listed but not navigable.

Under each file sit the symbols a hunk actually touched, plus the ancestors needed to
place them. Unchanged siblings are hidden: the tree is a map of the diff, not an outline.

```text
▎ session.ts                         +12 -3
  ├─󰌗 SessionStore › refresh › deadline  +8 -1
  ├─󰏿 SESSION_TTL                     +1 -0
  └─󰘦 Other changes                   +3 -2
▎ legacy/auth.ts  deleted
▎ Makefile                            +2 -0
  └─󰘦 Other changes                   +2 -0
```

## Visual system

Cohesion here means speaking the config's existing vocabulary, not inventing one. Every
glyph, colour and layout device below is already in use somewhere in this config.

### The status rail is the one bold element

Column 0 of every file row is a `▎` coloured by change type, drawn in **gitsigns' own
sign highlight groups** — `GitSignsAdd`, `GitSignsChange`, `GitSignsDelete`,
`GitSignsUntracked`. The colours are therefore identical to the signs already in the
margin, track the theme for free, and need no legend: it is the same language the gutter
already taught.

The rail is what makes the sidebar scannable as a map — you see three new files and one
deletion without reading a word. Everything else stays deliberately quiet. Because the
rail carries change type, added/modified files take no text marker; only `deleted` and
`renamed` do, where the old path is information the rail cannot hold.

### Icons come from mini.icons, never hand-picked

- Symbol rows: `MiniIcons.get("lsp", kind)` — the exact call `outline.lua` makes, so a
  method is the same glyph in the same hue in both the picker and the sidebar.
- File rows: `MiniIcons.get("file", path)`.
- Orphan-hunk groups: the `lsp`/`Text` icon, dimmed. Not a bespoke glyph.

A future icon-set change propagates everywhere at once. That is the point.

### Kind labels are dropped; the icon carries kind

The outline picker right-aligns a kind label (`Method`, `Class`). A sidebar is too narrow
to spend its right edge twice, and the kind icon already encodes kind in colour and form.
The right edge goes to the stat instead. This is the one place the sidebar deliberately
diverges from the picker, and it is a width decision, not a style one.

### Tree guides and chain separators are reused verbatim

`├─ └─ │` come from `symbols.flatten`'s existing `guides` field. A compressed chain joins
with ` › ` — `symbols.lua`'s existing `SEP`, the same separator its breadcrumbs use. No
new punctuation is introduced.

### Three levels of emphasis, all theme-derived

| Level | Used for | Group |
| --- | --- | --- |
| Content | a symbol whose own body changed | `Normal` |
| Context | ancestor-only rows — shown because a descendant changed | `Comment` |
| Meta | `⋯ reading symbols`, the orphan group's label | `Comment` + italic |

Italic means "this is not content" — the idiom `render.crumb_hl()` already establishes.
Nothing is bold: the outline picker uses no bold, and adding it would break the pairing.

Ancestor-only rows carry no stat. They did not change; only their descendants did.

### Stats

Right-aligned virtual text, `+N` in `GitSignsAdd`, `-N` in `GitSignsDelete`. Numbers, not
a bar — a bar would be decoration competing with the rail, and the rail already won.

### Winbar

```text
 vs origin/trunk      7 files  +142 -38
```

Sentence case, no separators-as-ornament, no all-caps label. It states the comparison
because "changed relative to what" is the one question the rows themselves cannot answer.

### Empty and failed states direct, never apologise

| Situation | Text |
| --- | --- |
| On the default branch | `On trunk — nothing to compare. Switch to a branch to see its changes.` |
| Branch with no diff | `<branch> matches origin/trunk. Nothing changed yet.` |
| Symbols still resolving | `⋯ reading symbols` under the file row |
| No LSP for a file | nothing special — the file renders with its orphan-hunk group |

What an empty subtree means is carried by the row, not inferred from it. A file row is
`resolved` once a server has answered for it, and only an unresolved row gets the
placeholder. That keeps three cases apart which all render childless: still waiting, a
`deleted` file, and a file with genuinely nothing to show inside it — a 100% rename, a
binary change.

## What it remembers

Asking a language server about every changed file is what makes the first open slow: 28
files take about nine seconds in this repo, and the tree fills a row at a time while it
waits. Symbols are cached per file instead, stamped with the file's size and mtime, so
reopening asks a server only about what has changed since — the same tree comes back
complete in under 300ms, which is the `git diff` and nothing else.

The cache is one JSON file per repo under `stdpath("cache")/prtree/`, holding only the
fields the tree reads from a symbol. Every open narrows it to the files the current diff
touches, so it stays the size of a branch rather than growing with every branch ever
reviewed, and losing it costs one slow open. Folds are remembered for as long as Neovim
is running, so reopening looks like you left it; a restart starts expanded.

## Keymaps

| Key | Where | Does |
| --- | --- | --- |
| `<leader>gP` | anywhere | closed → open+focus; open+unfocused → focus; open+focused → close, restore focus |
| `j` / `k` | sidebar | move, previewing into the pinned window without leaving the sidebar |
| `<CR>` | sidebar | commit: focus the pinned window at the row's position, keep the jump |
| `q` | sidebar | close, restore focus and the pinned window's original buffer |
| `h` / `l` | sidebar | collapse / expand; `l` on a compressed chain expands it to full nesting |
| `zM` / `zR` | sidebar | collapse / expand every file |
| `/` | sidebar | filter as you type, keeping ancestors so matches stay placed; `<Esc>` restores the last filter |
| `R` | sidebar | rebuild now |
| `y` | sidebar | yank the row's `path:line` via `helpers.yank` |
| `<C-v>` `<C-x>` `<C-t>` | sidebar | commit into a vsplit / split / new tab instead |
| `?` | sidebar | list these keys: which-key's popup where it is installed, a float where it is not |
| `]h` / `[h` | anywhere, while open | advance the sidebar's selection and jump — review without focusing the sidebar |

## Behaviour that is easy to get wrong

- **Preview is non-destructive.** `j`/`k` swap the pinned window's buffer and cursor for
  real, but `q` or `<leader>gP` restores the buffer *and* cursor it had at open. Only
  `<CR>` relocates you, and only `<CR>` writes a jumplist entry — previewing must not, or
  `<C-o>` becomes one entry per keypress.
- **The pinned window is captured at open** and used for the sidebar's lifetime, even for
  rows whose file another window already shows. Fallback when it dies: most recent normal
  window, else a new split.
- **Refresh re-anchors by identity, not line.** A rebuild keyed on `GitSignsUpdate` must
  restore the cursor to the same row *identity* and preserve collapse state, including an
  `l`-expanded chain. One key scheme serves all three.
- **Opening the sidebar is an ordinary split.** It takes its width with `winfixwidth`
  already set and then lets `'equalalways'` settle the rest, so the windows that were
  already open share out what is left instead of one of them being squashed.
- **A session restores the window, not the tree.** `:mksession` records the layout but
  not a scratch buffer's contents, so the sidebar comes back as an empty window. Its
  name is what survives, and it is how the tree finds that window and fills it rather
  than splitting a second sidebar beside it.
- **A cached file is never loaded.** Reading symbols is what puts a changed file in a
  buffer, so a file answered from the cache has none, and anything the tree needs from
  its text comes off disk instead.
- **Stamp a file before asking about it, not after.** A file edited while its symbols are
  being read has to fail the freshness check next time; stamping afterwards would file
  the answer under the content that replaced it.
- **Compression is view state, not data shape.** The row model always holds the full
  nesting; compression is applied at render and reversed by `l`.
