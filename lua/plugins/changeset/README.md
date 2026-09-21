# changeset

A read-only sidebar mapping what this branch changed, nested by symbol.

`<leader>gp` opens the *map* of what this branch changed. `<leader>gP` puts the *gutter*
in PR Review Mode over the same range. They are siblings and read the same base, but
neither drives the other.

## What it shows

Files changed between `merge-base(origin/<default>, HEAD)` — the local default branch
when there is no `origin/` copy of it — and the working tree: the
same range PR Review Mode's gutter marks, so the sidebar and the signs never disagree.
Untracked files count; deleted files are listed but not navigable.

Under each file sit the symbols a hunk actually touched, plus the ancestors needed to
place them. Unchanged siblings are hidden: the tree is a map of the diff, not an outline.

```text
▎ 󰛦 session.ts                       +12 -3
  ├─󰌗 SessionStore › refresh › deadline  +8 -1
  ├─󰏿 SESSION_TTL                     +1 -0
  └─󰘦 Other changes                   +3 -2
▎ 󰛦 legacy/auth.ts deleted
▎ 󰛡 Makefile                          +2 -0
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

### Tree guides and chain separators are the outline picker's

`├─ └─ │` are the guides the outline picker draws, and a compressed chain joins with
` › `, the separator its breadcrumbs use. Both are built here rather than carried over:
the picker's guides describe its own flat list, and this tree nests differently. The
separator is the one that has to stay identical, because `symbols.fit` trims a chain by
splitting it on its own copy. No new punctuation is introduced.

### Three levels of emphasis, all theme-derived

| Level | Used for | Group |
| --- | --- | --- |
| Content | a symbol whose own body changed | `Normal` |
| Context | ancestor-only rows — shown because a descendant changed | `Comment` |
| Meta | `⋯ reading symbols`, the orphan group's label | `Comment` + italic |

Italic means "this is not content" — the idiom `render.crumb_hl()` already establishes.
No row is bold: the outline picker uses no bold, and adding it would break the pairing.
The two badges are, because a badge is chrome rather than content.

Ancestor-only rows carry no stat. They did not change; only their descendants did.

### A filter leaves its matches lit

While a filter is in force every occurrence of it is painted in `Search` — the group the
editor already uses for "the text you went looking for" — above whatever colour the row
already carries, so a match reads over a dimmed ancestor as clearly as over a symbol name.
The runs are found in the rendered line rather than in the row's name, so a path trimmed
to `…a/plugins/changeset/window.lua` still lights the part you can actually see. They
last as long as the filter does, not as long as the prompt.

### The kind menu docks against the sidebar, and reuses its rail

`F` opens the list of symbol kinds this branch touched, as a float whose right border
sits on the cell the sidebar starts after:

```text
╭─ Symbol kinds ─────────────╮
│ ▎󰀫 Variable          1052  │
│ ▎󰊕 Function           523  │
│  󰏿 C̶o̶n̶s̶t̶a̶n̶t̶            242  │
│ ▎󰀬 String              17  │
╰─ unsaved changes ──────────╯
```

Docked rather than centred, and beside the tree rather than over it, because `x` redraws
the tree immediately — watching 242 rows leave is how the choice gets made, so the thing
being changed has to stay on screen.

Column 0 is the same `▎` rail the file rows use, carrying kind colour here where they
carry change type, so the menu reads as part of the tree rather than as a checkbox list.
A hidden kind loses the rail *and* is struck through: the rail's absence alone is a
negative signal, and dimming alone already means "ancestor row". The count is the tree's
own right edge, and it is what makes the list a decision rather than a form — `Variable
1052` is the reason the tree was unreadable.

Rows are ordered by weight, not alphabetically: the kind filling the tree is the one the
cursor starts nearest. Only kinds this branch actually touched are listed, so the menu is
four rows rather than the twenty-six LSP defines.

The border does the labelling. The title names the list; the footer says where the set on
screen is remembered — `set everywhere`, `set for this repo`, `set for this branch`, or
`showing every kind` when nothing has been saved. Once a toggle has drifted from what is
on disk it reads `unsaved changes` instead, because `q` throws that drift away and a
footer naming a scope would read as though it were safe. Keys are not listed there: `?`
answers that, the same way it does in the sidebar.

### A hidden kind is admitted under the tree

```text
▎ Makefile                            +2 -0
  └─󰘦 Other changes                   +2 -0

 Hiding variables and fields. F to change.
```

A virtual line, so the cursor cannot land on it and it needs no place among the rows. It
names the kinds while they fit, because *which* ones are missing is what stops a reader
hunting for a symbol that is there; past the width it counts them instead, since a clipped
list answers nothing. Only kinds the tree actually has are named — a set carried in from
another branch can hide things this one never had.

### Stats

Right-aligned virtual text, `+N` in `GitSignsAdd`, `-N` in `GitSignsDelete`. Numbers, not
a bar — a bar would be decoration competing with the rail, and the rail already won.

### Header

```text
 vs origin/trunk                         7 files  +142 -38
```

Sentence case, no separators-as-ornament, no all-caps label. It states the comparison
because "changed relative to what" is the one question the rows themselves cannot answer,
and wears it as a reversed badge — the shape the strip over a borrowed window uses, since
both answer what a window is holding before anything in it does. The badge takes
`Directory`'s colour rather than that strip's warning yellow, which is spoken for by "on
loan", and the strip behind it is `TabLine`'s background: what a colorscheme paints its own
chrome with, and not the shade the sidebar draws its cursor line in — a header the colour
of a row is a row. The totals hang off the right edge, in the column the per-row stats already occupy, so
the branch's numbers and each file's numbers read down one edge instead of two.

### A borrowed window says so

A preview swaps a real window's buffer out from under you, so that window wears a band
across its top for as long as the sidebar holds it:

```text
 Preview  󰛦 session.ts                     SessionStore › refresh › deadline
```

Four runs answering the three questions a borrowed window raises, in the order they are
asked: what is this, what am I looking at, where does `<CR>` put me — the icon and the path
answer the middle one together, under the same glyph the tree files it by. The right edge
carries the destination rather than the file, because the file is on the left and the row
under the cursor is not: a chain is shown the way the tree shows it, joined by ` › `. A
row that names no destination — a file, an orphan hunk — reads `<CR> to open` instead.
`%<` sits before the path, so a window too narrow for all three gives up the part the
sidebar is already showing. The badge is `reverse`d
rather than given a looked-up background, so it pairs the theme's warning colour with
whatever the window is actually drawn on and survives a theme that leaves `Normal`
transparent. The band behind it is `CursorLine`'s background — the faintest tint every
colorscheme gives a window to say "this is the thing you are on", quiet enough to sit over
a file rather than in front of it — and it runs the full width, which is why a band rather
than a border: a split cannot have one, and the sidebar already speaks winbar. The icon
gets a group of its own recoloured onto that background, because a `MiniIcons` group
carries a foreground only and the glyph would otherwise punch the window's own background
through the band.

The band goes the moment the window stops previewing — `q` puts it back with the buffer,
and `<CR>` clears it, because a file you chose is not on loan.

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

The cache is one JSON file per repo under `stdpath("cache")/changeset/`, holding only the
fields the tree reads from a symbol. Every open narrows it to the files the current diff
touches, so it stays the size of a branch rather than growing with every branch ever
reviewed, and losing it costs one slow open. Folds are remembered per repository for as long as
Neovim is running, so reopening looks like you left it; a restart starts expanded. Per
repository because a row is identified by a repo-relative path, which two checkouts can
easily both have.

## Settings

There are none, and opening the sidebar changes nothing outside it — the gutter is
`<leader>gP`'s to switch on, including its memory of you having switched it off.

Which symbol kinds are hidden is not a setting either: it is a choice made in the menu and
written to `stdpath("state")/changeset/filters.json`, through a temporary file renamed over
the old one, so an interrupted write leaves the last good copy standing. Three scopes,
narrowest first —
this branch, this repository, everywhere — and a scope counts as set by *having* a record,
not by that record hiding anything, so a branch that hides nothing overrides a repository
that hides something. That is the only way "show me everything, just here" can be said.

Saving at a scope clears the narrower records that would shadow it: saving everywhere from
a repository with its own record would otherwise change nothing in front of you, and the
word would be a lie. Only records shadowing *this* repo and branch go — another
repository's deliberate choice is none of that save's business.

## Keymaps

| Key | Where | Does |
| --- | --- | --- |
| `<leader>gp` | anywhere | closed → open+focus; open+unfocused → focus; open+focused → close, restore focus |
| `j` / `k` | sidebar | move, previewing into the window you were last in, without leaving the sidebar |
| `<CR>` | sidebar | commit: focus that window at the row's position, keep the jump |
| `<S-CR>` | sidebar | commit, then close the sidebar behind you |
| `q` | sidebar | close, restore focus and put back whatever the previews borrowed |
| `h` / `l` | sidebar | collapse / expand; `h` with nothing left to shut steps out to the parent, so repeated `h` walks up to the filename; `l` on a compressed chain expands it to full nesting |
| `H` / `L` | sidebar | collapse / expand every file, the whole-tree form of `h` / `l` |
| `F` | sidebar | open the symbol-kind menu |
| `x` | kind menu | hide or show the kind under the cursor, redrawing the tree at once |
| `<CR>` / `r` / `b` | kind menu | remember this set everywhere / for this repository / for this branch, then close |
| `q` / `<Esc>` | kind menu | close, putting the tree back to the set on disk |
| `f` | sidebar | filter as you type, keeping ancestors so matches stay placed and lighting every match until the filter goes; `<Esc>` restores the last filter |
| `R` | sidebar | rebuild now |
| `y` | sidebar | yank the row's `path:line` via `helpers.paths.copy` |
| `/` `-` `<C-t>` | sidebar | commit into a vsplit / split / new tab instead |
| `?` | sidebar | list these keys, `]h` / `[h` included: which-key's popup where it is installed, a float where it is not |
| `]h` / `[h` | anywhere, while open | advance the sidebar's selection, previewing as it goes — review without focusing the sidebar |

## Behaviour that is easy to get wrong

- **Preview is non-destructive.** `j`/`k` swap a window's buffer and cursor for real, but
  `q` or `<leader>gp` puts back every window a preview borrowed, buffer *and* cursor. Only
  `<CR>` relocates you, and only `<CR>` writes a jumplist entry — previewing must not, or
  `<C-o>` becomes one entry per keypress.
- **Previews follow the window you were last in** — the focused one, or, while the cursor
  is in the sidebar, the one it came from. `winnr("#")` answers 0 once that window has
  been closed, and 0 is an alias for the current window wherever it would then be passed,
  so it has to be dropped rather than carried through. Nothing usable at all: the rest of
  the tabpage, then a split of its own.
- **A previewed file is highlighted, not opened.** Its buffer stays unlisted until `<CR>`
  promotes it, but it carries a filetype, so treesitter, syntax and any language server
  attach to it exactly as they would to a file you opened. The filetype has to be named
  explicitly: previews happen in a `CursorMoved` callback, autocommands do not nest, and
  the read therefore skips the `BufRead` chain that would otherwise detect one.
- **`?` documents the sidebar, not its buffer.** A buffer collects mappings from whoever
  wants one — a blanket `FileType` autocmd elsewhere in the config is all it takes — and
  those keys are not this sidebar's interface. The keys it sets are recorded as it sets
  them, and which-key is handed a throwaway buffer carrying only those, since it describes
  whatever a buffer maps and takes no say in which. The callbacks travel across with the
  keys, so pressing one from inside the popup still works. `]h` / `[h` are global rather
  than buffer-local, so they are looked up by name and added to that buffer, or they would
  be the two keys the reference never mentions.
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
- **Only an answer is cached.** A server that never attached, and a file whose buffer held
  unwritten edits when it was read, are both left out: a stamp taken off the file on disk
  cannot describe either, and either one filed as fresh would outlive the edit that made
  it wrong — across restarts, until the file next moves.
- **One line is one row, one level below its parent.** `h` and the cursor anchor both read
  the next line's depth to decide what is showing, so the `⋯ reading symbols` placeholder
  is a row of its own rather than the file's row drawn a second time.
- **Hiding a kind promotes its children.** Dropping `Class` still shows the methods that
  changed inside one — the kind you hid is not the thing you were looking for. Same rule
  `symbols.flatten` applies to its own kind filter, for the same reason.
- **Counts come off the unfiltered tree.** A hidden kind still has to report its size, or
  the menu could not tell you what putting it back would cost.
- **A float's border is drawn outside the size it is given.** Anchoring the menu by its
  own north-east corner against the sidebar leaves the border unaccounted for and three
  dead cells with it; the position is computed in editor cells instead, so the right
  border lands on the cell the sidebar starts after.
- **The menu reads the row under its own cursor, not the current one.** `?` hands the keys
  to a which-key float, and they have to keep acting on the menu.
- **Compression is view state, not data shape.** The row model always holds the full
  nesting; compression is applied at render and reversed by `l`.
