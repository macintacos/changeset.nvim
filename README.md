# changeset

A read-only sidebar mapping what this branch changed, nested by symbol.

`<leader>gp` opens the *map* of what this branch changed. `<leader>gP` puts the *gutter*
in PR Review Mode over the same range. Neither drives the other. `<leader>gj` searches the
same changes in a picker (`MiniPick.registry.changeset`, in `mini-pickers`).

In an editor too narrow to leave the files 80 columns beside it, the sidebar opens as a
drawer along the bottom instead, and moves between the two as the editor is resized.

## What it shows

Files changed between `merge-base(origin/<default>, HEAD)` — the local default branch
when there is no `origin/` copy of it — and the working tree: the
same range PR Review Mode's gutter marks. On a branch whose open PR targets another branch,
that branch stands in for the default once `gh` names it, and the tree rebuilds onto it.
Untracked files count. A deleted file is listed, but its row previews a notice
in place of the file and never opens it.

Under each file sit the symbols a hunk actually touched, plus the ancestors needed to
place them. Unchanged siblings are hidden: the tree is a map of the diff, not an outline.

Files sit under Implementation / Tests / Docs / Config headers, in that order, and are
grouped by directory within their section, a directory's own files ahead of its
subdirectories'.

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

A file row leads with the filename, its directory dimmed in parentheses after it and
trimmed from the front before the name ever is.

### Sections

```text
󱞊  Tests               3 files      +40 -2
```

A header is the section's `MiniIcons.get("directory", …)` icon, its label as plain
content, the file count in the meta colour, and a right-aligned `+N -N` for the whole
section — the same stat chunks a file row draws. The count and stat are the section's
own, taken before any filter, so they stay put while a filter thins the files beneath. A
header carries no rail and is never lit as a filter match; it stays on screen only while
one of its rows matches.

An empty section is left out. A lone section is still headed, so what a file was
classified as is always on screen. Files are not indented under their header: the rail
stays in column 0, where the eye already scans for it. A blank virtual line hangs between
sections — not a row, so the cursor cannot land on it.

`h` / `l` on a section header fold and unfold the section, and the fold is remembered per
repo like a file's. `]]` / `[[` move from header to header, a folded one included.

Generated renders last and starts folded the first time a repository shows it; `l` unfolds
it and that is remembered like any other fold, and, like every section, `L` leaves it as it
is. Its files are never sent to a language server, so they show no `reading symbols` row
and no symbols — a Generated file is one line.

Classification starts from the path, plus whether the file's Go header or
`.gitattributes` marks it generated. Generated is checked first and beats every other
rule; then Tests → Docs → Config, and the first match wins; anything unmatched is
Implementation. A directory rule matches any directory segment, not just the first.

- **Generated** — `*.lock`, `*-lock.json`, `*-lock.yaml`, `go.sum`,
  `nvim-pack-lock.json`; a `.go` file with a `// Code generated … DO NOT EDIT.` line before
  its `package` clause; or a path `.gitattributes` marks `linguist-generated`. A deleted
  file goes by name and attribute alone.
- **Tests** — a `tests`, `test`, `spec`, `__tests__` or `testdata` directory; or a file
  named `*_spec.*`, `*_test.*`, `*.test.*`, `*.spec.*`, `test_*.py`, `conftest.py` or
  `*.bats`.
- **Docs** — `*.md`, `*.mdx`, `*.rst`, `README*`, `CHANGELOG*`; or a `*.txt` under a `doc`
  or `docs` directory.
- **Config** — `*.toml`, `*.yaml`, `*.yml`, `*.pkl`, `*.json`, `*.ini`, `*.cfg`, any
  dotfile, `Makefile`, `Dockerfile`, `go.mod`; or anything under `.github` that is not a
  script (`*.sh`, `*.bash`, `*.py`, `*.js`, `*.ts`, `*.rs`, `*.go`, `*.lua`).

So `plugin/lsp.lua` is Implementation although it configures something, and so is
`.mise/tasks/test`: `test` there is a file name, not a directory, and a dotted directory
is not a dotfile. And `tests/fixtures/package-lock.json` is Generated, not Tests.

Rust, Python and TypeScript keep tests inside implementation files, so for those a
file's symbols get a second look — only when the path rules put it in Implementation, and
only once its symbols are in. A symbol goes to Tests, with everything beneath it, when it
is a Module or Namespace named `test` or `tests` (all three languages); a Python
`test_*` function or `Test*` class; or a TypeScript `describe` / `it` / `test` callback,
which tsserver names after its call, as in `describe('refresh') callback`. Whatever its
name, a symbol also goes to Tests when its syntax marks it: a Rust item under `#[test]`,
`#[<path>::test]` (`#[tokio::test]`) or `#[cfg(test)]`, with everything inside it, and
every symbol inside a TypeScript `if (import.meta.vitest) { … }` block. Those rules
parse, with treesitter, the text the server answered for, so a file without an installed
parser keeps just the name rules. They match exactly: `cfg(test)` alone, not
`cfg(all(test, …))`.

```text
󰴉  Implementation      1 file   +16 -4
▎ 󰛦 session.rs              +16 -4
  ├─󰌗 SessionStore › refresh  +8 -1
  └─󰘦 Other changes          +3 -2

󱞊  Tests               1 file    +8 -0
▎ 󰛦 session.rs               +8 -0
  └─󰆧 tests › refreshes        +8 -0
```

A file whose changes reach both shows under Implementation and Tests, each copy listing
only its own symbols; `Other changes` stays on the Implementation copy. Each copy counts
toward its own section's header. The Tests copy's `+N` is the added lines inside test
symbols and its `-N` the removed lines of hunks whose first symbol is a test; the
Implementation copy takes the rest, so the two sum to the file's. A copy with nothing to
list is left out, and the one left carries the file's whole stat. Go, Lua and bash get no
symbol rules: their tests live in files the path rules already catch.

### Icons come from mini.icons, never hand-picked

- Symbol rows: `MiniIcons.get("lsp", kind)` — the exact call `outline.lua` makes, so a
  method is the same glyph in the same hue in both the picker and the sidebar.
- File rows: `MiniIcons.get("file", path)`.
- Section headers: `MiniIcons.get("directory", …)` with `src`, `tests`, `docs`,
  `.config` and `build`, so each header wears the icon its kind of directory already has.
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
The runs are found in the rendered line rather than in the row's name, so a directory
trimmed to `(…/plugins/changeset)` still lights the part you can actually see. They
last as long as the filter does, not as long as the prompt.

### Three rows say what is selected, where you are and what you opened

```text
▎ 󰢱 more.lua                         +7 -0 ◀
  ├─ M.setup                        +3 -1 •
  └─ Other changes                  +1 -1 ◁
```

The only row highlights the tree has. **Selected** is the row under the sidebar's cursor,
shown only while the sidebar has focus. **You are here** is the row for the file and line
the cursor is in, shown always. **Picked** is the row last opened from the sidebar —
`<CR>`, a split or tab key, or moving into a preview — which stays put as you move around
the file it opened. A row several would mark shows the first of those, so right after a
pick its row shows you are here, and the pick appears once you move off it.

All three tint the whole row toward the theme's keyword colour (`Statement`, mauve in
catppuccin), a hue nothing else on a row carries, so a tinted row reads as a state rather
than as another diff colour, each fainter than the one before. You are here wears the
selection's glyph hollowed out and the pick a dot: `◀` for the selection, `◁` for you, `•`
for the pick, in a two-cell gutter every row leaves at its right edge, past the stat. The
tint is mixed over `Normal`'s
background, or `TabLine`'s when `Normal` is transparent, rather than linked, so every
token keeps its own colour on top. It draws beneath every row mark, so the rail, the row
colours and a filter match stay on top; the glyph draws over the stat's blank tail.

The cursor itself is hidden while it is in the sidebar, and the selected row stands in for
it: the cursor would sit on each row's first cell, which on a section header is its icon.
Only in normal and visual mode, so a prompt on the command line still shows one. It hides
through a `'guicursor'` entry whose group is fully blended, which needs `termguicolors`; a
plugin that appends its own entry on entering a window, as modes.nvim does, has to skip
the `changeset` filetype or its entry wins. mini.cursorword is off in the sidebar, as the
hidden cursor rests on each row's rail and it would underline that.

A line belongs to the deepest symbol row whose body holds it, else to the file's
`Other changes` row when one of its hunks does, else to the file row. A file shown in two
sections answers from the copy with the deeper match, and falls back to the path
section's copy. When the row is off screen — folded, filtered, or inside a compressed
chain — its nearest visible ancestor wears the highlight instead.

Focusing the sidebar, by `<leader>gp`, a click or `<C-w>`, puts its cursor on that same
row, and previews it the way moving onto it would. Focused before your file's symbols
are in, it lands on the file row and follows you into your symbol when they arrive,
unless you have moved the cursor or left the sidebar by then. From a file outside the
changeset the cursor stays where you left it. Closing the kind menu is not a new arrival:
you never left the sidebar for it, so the cursor stays on the row you were on.

A terminal or help window is not a file you are in either, so it leaves "you are here"
where it was. Both that and the row the sidebar's cursor is on ride the session, in the
`ChangesetPosition` global: restoring one puts each back once the rebuilt tree has read
its file's symbols (a deleted file has none to wait for), unless you have moved into a
file, into the sidebar, or the sidebar's cursor by then. A file or row the changeset no
longer holds is let go without a word.

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
being changed has to stay on screen. A drawer leaves no room beside it, so there the menu
stands on top of it instead.

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

A symbol's `+N` counts only the changed lines falling inside its own range, so a hunk
running across two symbols gives each one its own share and the lines in the gap between
them to neither. A file's `+N` is git's count for the whole file and can therefore exceed
the sum of its symbols'. A file split across Implementation and Tests shows its own share
on each copy, and the shares sum to git's count. Removed lines have no position in the
new file to split on, so a hunk's `-N` goes wholly to the first symbol it reaches.

### Header

```text
  origin/jt/exc-1200-stacked-parent…  #412
  4 files            2 commits  +142 -38

󰴉  Implementation      2 files      +12 -3
▎ 󰛦 session.ts                       +12 -3
```

Two rows on one strip, the strip `TabLine`'s background: what a colorscheme paints its own
chrome with, so the header reads as the panel's frame.

The first row states the ref the tree is compared against, because "changed relative to
what" is the one question the rows themselves cannot answer. It leads with mini.statusline's
own branch glyph in `Directory`'s colour, and dims `origin/` so the branch name reads first.
A ref too long for the width loses its tail, never its head: stacked branches are told apart
by how their names start, which is why the cut is made here rather than by the statusline's
`%<`, which keeps the tail. The branch's open PR sits at the right edge while the tree is
measured against the branch that PR merges into.

The second row counts what the branch holds, the numbers lit and their nouns dimmed: files
on the left, commits at the right beside the line totals, which end in the column the
per-row stats end in, short of the state gutter, so the branch's numbers and each file's
read down one edge instead of two. While symbols are being read, `⋯ reading symbols 12/28`
takes the file count's place and the commits give it their room; Generated files count as
read from the start.

A split has one winbar row, so the second row is a virtual line above the tree's first, with
a blank one under it. Neovim treats lines above the first as filler and leaves them out of
view unless asked, so the sidebar scrolls them back in whenever it returns to its top; they
scroll away with the tree like any row would. Until the first diff is in the row is absent,
rather than claiming that nothing changed.

### Footer

```text
 Changeset  file 3 of 12  󰈲 sess           <CR> open  f filter  F kinds  ? all keys
```

The sidebar's own `statusline`. With `laststatus=3` a window's own statusline is drawn
only while that window has focus, so it takes the global bar's place exactly when the
sidebar's keys are worth naming, and hands it back the moment you leave. The badge is
the header glyph's `Directory` colour, reversed, standing where the mode badge would. The
position counts the files on screen — a folded section's files are not — and names no
file while the cursor is on a section header. A file shown in two sections counts once, at
its first row. The filter in force is named, since once its prompt closes the lit matches
are the only other trace of it. Only four keys are offered — `?` lists the rest.

The sidebar turns off `scrollEOF.nvim`, which would otherwise scroll the tree past its end
on opening and push its first row off the top.

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
and a commit clears it — `<CR>`, or simply entering the window — because a file you chose
is not on loan. The window the cursor is in never wears it at all: a `]h` pressed there
previews without a band, and one that came along with a buffer or a split comes off the
moment that window takes focus or a buffer.

### Empty and failed states direct, never apologise

| Situation | Text |
| --- | --- |
| On the default branch | `On trunk — nothing to compare. Switch to a branch to see its changes.` |
| Branch with no diff | `<branch> matches origin/trunk. Nothing changed yet.` |
| Symbols still resolving | `⋯ reading symbols` under the file row |
| No LSP for a file | nothing special — the file renders with its orphan-hunk group |

The two sentences wrap at the sidebar's edge, which no row does: a row is trimmed to fit.

What an empty subtree means is carried by the row, not inferred from it. A file row is
`resolved` once a server has answered for it, and only an unresolved row gets the
placeholder. That keeps three cases apart which all render childless: still waiting, a
`deleted` file, and a file with genuinely nothing to show inside it — a 100% rename, a
binary change.

## What it remembers

The tree is built the first time something asks for it — `<leader>gp`, `<leader>gj`, or a
restored session refilling the sidebar — for the current buffer's repository: the fork
point is measured at once, the diff and symbols in the background. Reading symbols loads
each changed file the cache can't answer, Generated ones aside, so those buffers and their
language servers arrive with that first ask, and a session that never asks starts none.
The picker waits a moment for the diff, which it has no way to fill in behind. The sidebar
opens at once: a tree still waiting on its first diff opens blank rather than claiming
nothing changed. Closing the sidebar lets go of the window only, and opening it again
draws the tree it kept and refreshes its diff in the background. The tree is rebuilt for a
different repository, fork point or branch, and a build that finds no fork point keeps the
tree it had.

Once built, the tree re-reads the diff whenever the files it diffs can have moved, whether
or not the sidebar is showing: after a write, when a buffer is reloaded because its file
changed outside Neovim, when Neovim regains focus, and when gitsigns sees HEAD move. Its
per-buffer `GitSignsUpdate` is not one of them. It fires on every attach and every hunk
change while typing, none of which moves a diff git reads from disk, and the symbol walk's
own buffer loads would fire it too, restarting the walk they came from.

Asking a language server about every changed file is what makes a cold build slow: 28
files take about nine seconds in this repo, and the tree fills a row at a time while it
waits. Symbols are cached per file instead, stamped with the file's size and mtime, so
the next build asks a server only about what has changed since — the same tree comes back
complete in under 300ms, which is the `git diff` and nothing else.

The cache is one JSON file per repo under `stdpath("cache")/changeset/`, holding only the
fields the tree reads from a symbol. Every refresh narrows it to the files the current diff
touches, so it stays the size of a branch rather than growing with every branch ever
reviewed, and losing it costs one slow build. An entry also records which symbols the
syntax marked as tests, so a cached file is never parsed again. The file name carries a
format number, bumped whenever an entry gains a field, because an older entry's stamp would
otherwise still match. Folds — a section's as well as a file's — are remembered per
repository for as long as Neovim is running, so reopening looks like you left it; a restart
starts expanded, except Generated, which starts folded. Per repository because a row is
identified by a repo-relative path, which two checkouts can easily both have.

## Settings

There are none, and the sidebar leaves the gutter alone — that is
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
| `<leader>gp` | anywhere | closed → open+focus on the row you are on; open+unfocused → focus on the row you are on; open+focused → close, restore focus |
| `j` / `k` | sidebar | move, previewing into the window you were last in, without leaving the sidebar |
| `<CR>` | sidebar | commit: focus that window at the row's position, keep the jump; nothing on a section header |
| `<S-CR>` | sidebar | commit, then close the sidebar behind you |
| `q` | sidebar | close, restore focus and put back whatever the previews borrowed |
| `h` / `l` | sidebar | collapse / expand; on a header, fold / unfold its section; `h` with nothing left to shut steps out to the parent, so repeated `h` walks up to the filename and then its section header; `l` on a compressed chain expands it to full nesting |
| `H` / `L` | sidebar | collapse / expand every file, the whole-tree form of `h` / `l`; never folds or unfolds a section |
| `]]` / `[[` | sidebar | move to the next / previous section header, a folded one included; stays put when there is none that way |
| `F` | sidebar | open the symbol-kind menu |
| `x` | kind menu | hide or show the kind under the cursor, redrawing the tree at once |
| `<CR>` / `r` / `b` | kind menu | remember this set everywhere / for this repository / for this branch, then close |
| `q` / `<Esc>` | kind menu | close, putting the tree back to the set on disk |
| `f` | sidebar | filter as you type, keeping ancestors so matches stay placed and lighting every match until the filter goes; `<Esc>` restores the last filter |
| `R` | sidebar | rebuild now |
| `y` | sidebar | yank the row's `path:line` via `changeset.paths.copy`; nothing on a section header |
| `/` `-` `<C-t>` | sidebar | commit into a vsplit / split / new tab instead |
| `?` | sidebar | list these keys, `]h` / `[h` included: which-key's popup where it is installed, a float where it is not |
| `]h` / `[h` | anywhere, while open | advance the sidebar's selection, previewing as it goes and stepping over section headers — review without focusing the sidebar |

## Behaviour that is easy to get wrong

- **A file cached before its parser was installed keeps just the name rules** until it
  next changes: its entry was read without the syntax layer, and its stamp still matches.
- **Preview is non-destructive.** `j`/`k` swap a window's buffer and cursor for real, but
  `q` or `<leader>gp` puts back every window a preview borrowed, buffer *and* cursor.
  Only a commit — `<CR>` and its split variants, or entering the previewed window — keeps
  the file there and writes a jumplist entry, sending `<C-o>` back to where the window
  stood before the sidebar opened rather than to the last preview — previewing must not
  write one, or `<C-o>` becomes one entry per keypress. Entering counts only as an
  arrival: a preview `]h` made in the window the cursor was already in stays a preview
  however focus leaves and returns, until `<CR>` or `q`.
- **Previews follow the window you were last in** — the focused one, or, while the cursor
  is in the sidebar, the one it came from. `winnr("#")` answers 0 once that window has
  been closed, and 0 is an alias for the current window wherever it would then be passed,
  so it has to be dropped rather than carried through. Nothing usable at all: the rest of
  the tabpage, then a split of its own.
- **A previewed file is highlighted, not opened.** Its buffer stays unlisted until a
  commit promotes it — `<CR>`, or the cursor arriving in its window by any route (mouse,
  `<C-w>`, `:wincmd`, another plugin). A deleted row's notice is the exception: it stands
  in for a file that cannot be opened, so arriving in it chooses nothing. It carries a
  filetype, so treesitter, syntax and any language server attach to it exactly as they
  would to a file you opened. The filetype has to be named explicitly: previews happen in
  a `CursorMoved` callback, autocommands do not nest, and the read therefore skips the
  `BufRead` chain that would otherwise detect one. gitsigns is attached explicitly for the
  same reason: `BufRead` is what it attaches on.
- **`?` documents the sidebar, not its buffer.** A buffer collects mappings from whoever
  wants one — a blanket `FileType` autocmd elsewhere in the config is all it takes — and
  those keys are not this sidebar's interface. The keys it sets are recorded as it sets
  them, and which-key is handed a throwaway buffer carrying only those, since it describes
  whatever a buffer maps and takes no say in which. The callbacks travel across with the
  keys, so pressing one from inside the popup still works. `]h` / `[h` are global rather
  than buffer-local, so they are looked up by name and added to that buffer, or they would
  be the two keys the reference never mentions.
- **The selection is the focused sidebar's cursor.** It moves with the cursor, in step
  rather than a tick behind, and goes when focus leaves the sidebar, for a float opened
  from it too, leaving "you are here". Previews never count as being somewhere: the
  tracker reads focus on the next tick, after a preview's buffer swap inside the borrowed
  window has finished, and ignores the sidebar and floats. It runs whether or not the
  sidebar is showing, and each redraw resolves "you are here" against the rebuilt tree.
- **Only a pick moves the pick.** `gd`, a picker or `:edit` into another changed file moves
  "you are here" and leaves the pick where it was. Each redraw resolves it against the
  rebuilt tree, so a picked row that a rebuild removed is found again from its file and
  line.
- **Landing happens on arrival, not on every move.** It hangs off `WinEnter` on the
  sidebar, never `CursorMoved`, so the cursor moves freely once you are there. It sets
  the cursor, and remembers the row so a rebuild can follow you deeper; only a rebuild
  (new rows) follows, never a fold or filter redraw. The preview comes from the
  sidebar's own `CursorMoved`, which Neovim fires once the cursor is in a new window.
- **Refresh re-anchors by identity, not line.** A rebuild must
  restore the cursor to the same row *identity* and preserve collapse state, including an
  `l`-expanded chain. One key scheme serves all three. Every redraw re-anchors the same
  way; when the cursor's file row is gone from screen — its changes all turned out to be
  tests, or a filter kept only one copy — the cursor moves to the first file row with that
  path.
- **Opening the sidebar is an ordinary split.** It takes its width with `winfixwidth`
  (a drawer its height, with `winfixheight`) already set and then lets `'equalalways'`
  settle the rest, so the windows that were already open share out what is left instead
  of one of them being squashed.
- **Switching to the drawer moves the window, never reopens it.** Previews, the claim on
  entering one, and the autocmds that watch the sidebar all hold its window id, which
  `nvim_win_set_config` keeps. Neovim will not move the last window, so a sidebar standing
  alone stays where it is.
- **A session restores the window, not its contents.** `:mksession` records the layout but
  not a scratch buffer's contents, so the sidebar comes back as an empty window. Its
  name is what survives, and it is how the tree finds that window and fills it rather
  than splitting a second sidebar beside it.
- **A cached file is never loaded or parsed.** Reading symbols is what puts a changed file
  in a buffer, so a file answered from the cache has none, and anything the tree needs
  from its text comes off disk instead. The test flag its attributes gave each symbol
  comes back with the symbol.
- **Stamp a file before asking about it, not after.** A file edited while its symbols are
  being read has to fail the freshness check next time; stamping afterwards would file
  the answer under the content that replaced it. The same stamp is why an answer is filed
  even after a newer refresh has replaced the one that asked: it still describes what the
  server read, so a refresh never throws away a walk's progress.
- **Only an answer is cached.** A server that never attached, and a file whose buffer held
  unwritten edits when it was read, are both left out: a stamp taken off the file on disk
  cannot describe either, and either one filed as fresh would outlive the edit that made
  it wrong — across restarts, until the file next moves.
- **No answer is remembered, but only in memory.** A file no server answers for — `go.sum`,
  a `Makefile` — is not asked about again on every refresh, each of which would wait out
  the attach timeout under a `reading symbols` row, and every write refreshes the tree.
  The file is asked about again once it moves, or once a server that lists symbols
  attaches to it, which is how a slow or newly installed server still gets heard.
- **One line is one row, one level below its parent.** `h` and the cursor anchor both read
  the next line's depth to decide what is showing, so the `⋯ reading symbols` placeholder
  is a row of its own rather than the file's row drawn a second time. A file sits one
  level below its section header though drawn unindented, which is why `h` steps out to it.
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
