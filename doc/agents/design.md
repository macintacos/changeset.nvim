# Design

This records why the sidebar looks and behaves as it does, for contributors; `README.md`
is the user reference.

## Visual system

Cohesion here means speaking the vocabulary of the Neovim config the plugin was extracted
from, not inventing one. Every glyph, colour and layout device below is already in use
somewhere in that config.

### The status rail is the one bold element

Every file row leads with a `▎` coloured by change type, drawn in **gitsigns' own
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

A header is the section's directory icon, its label as plain content, the file count in
the meta colour, and a right-aligned `+N -N` for the whole section — the same stat chunks
a file row draws. The count and stat are the section's own, taken before any filter, so
they stay put while a filter thins the files beneath. A header carries no rail and is
never lit as a filter match; it stays on screen only while one of its rows matches.

An empty section is left out. A lone section is still headed, so what a file was
classified as is always on screen. Files are not indented under their header: the rail
stays in the header icon's column, where the eye already scans for it. Every row opens
with one blank cell, as the header's do, so the tree's icons line up under the header's
glyphs. A blank virtual line hangs between sections — not a row, so the cursor cannot land
on it.

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
only its own symbols and hunks; each copy counts toward its own section's header, its stat
as § Stats splits it. A copy with nothing to list is left out, and the one left carries
the file's whole stat. Go, Lua and bash get no symbol rules: their tests live in files the
path rules already catch.

A change that touches only comments shows under a Docs copy of its file, whatever section
its path gives it. The unit is a changed symbol, or a hunk outside every symbol, which
lands under the Docs copy's `Other changes`. A unit goes to Docs when its changed lines
hold at least one comment line and no code line; any code line keeps it where it lands
today. Treesitter decides each line's kind, on the new side for added lines and on the
base for removed ones:

- A **comment** line is covered from its first to its last non-blank character by one
  comment node, or by a Python docstring. `x = 1  # note` is code.
- A **directive** is a comment that tells a tool what to do, such as `#!`, `//go:`,
  `// eslint-…`, `// @ts-…`, `---@diagnostic`, `-- selene:`, `-- stylua:`, `# type:`,
  `# noqa`, `# pylint:` or `# fmt:`. It counts as code, so changing one is not a docs
  change. Every other LuaCATS annotation, such as `---@param`, is a comment.
- A **blank** line counts as neither, so a unit whose only change is blank lines stays
  put.

A doc comment belongs to the declaration below it: a symbol's range reaches up over the
comment and directive lines directly above it, stopping at the previous sibling and at its
parent's own first line, never the parent's doc comment. So editing a function's doc
comment moves that function to Docs, and a class's first method still takes its own. A
removed line counts as code when git cannot read the base, and a file whose parser is not
installed, or fails to parse, keeps today's placement. The language comes from the file's
name and contents, so an extensionless shebang script is read too. Generated files and
files the path rules already put in Docs are left alone: neither their base nor their
comments are read.

```text
 󰴉  Implementation      1 file    +6 -1
 ▎ 󰌠 session.py               +6 -1
   └─󰊕 refresh                  +6 -1

 󱂷  Docs                1 file    +3 -1
 ▎ 󰌠 session.py               +3 -1
   └─󰊕 load                     +3 -1
```

### Icons come from an icon plugin, never hand-picked

`changeset.icons` asks mini.icons when it is set up, else nvim-web-devicons, else draws a
blank. devicons covers files only, so under it every other icon — section headers,
symbols, orphan hunks, the kind menu — is a blank in `Normal`. The provider is picked
once, on the first icon drawn; an icon plugin set up after that is not seen until Neovim
restarts. With mini.icons:

- Symbol rows: `MiniIcons.get("lsp", kind)` — the exact call that config's outline picker
  makes, so a method is the same glyph in the same hue in both the outline picker and the
  sidebar.
- File rows: `MiniIcons.get("file", path)`.
- Section headers: `MiniIcons.get("directory", …)` with `src`, `tests`, `docs`,
  `.config` and `build`, so each header wears the icon its kind of directory already has.
- Orphan-hunk groups: the `lsp`/`Text` icon, dimmed. Not a bespoke glyph.

A future icon-set change propagates everywhere at once. That is the point.

### Kind labels are dropped; the icon carries kind

The config's outline picker right-aligns a kind label (`Method`, `Class`). A sidebar is
too narrow to spend its right edge twice, and the kind icon already encodes kind in colour
and form. The right edge goes to the stat instead. This is the one place the sidebar
deliberately diverges from the outline picker, and it is a width decision, not a style
one.

### Tree guides and chain separators are the outline picker's

`├─ └─ │` are the guides the outline picker draws, and a compressed chain joins with
` › `, the separator its breadcrumbs use. Both are built here rather than carried over:
the outline picker's guides describe its own flat list, and this tree nests differently.
The separator is the one that has to stay identical, because `symbols.fit` trims a chain
by splitting it on its own copy. No new punctuation is introduced.

### Three levels of emphasis, all theme-derived

| Level | Used for | Group |
| --- | --- | --- |
| Content | a symbol whose own body changed | `Normal` |
| Context | ancestor-only rows — shown because a descendant changed | `Comment` |
| Meta | `⋯ reading symbols`, the orphan group's label | `Comment` + italic |

Italic means "this is not content" — the idiom the outline picker's breadcrumbs already
establish. No row is bold: the outline picker uses no bold, and adding it would break the
pairing. The two badges are, because a badge is chrome rather than content.

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
it: the cursor would sit on each row's first cell, a block in the margin beside the row.
Only in normal and visual mode, so a prompt on the command line still shows one. It hides
through a `'guicursor'` entry whose group is fully blended, which needs `termguicolors`; a
plugin that appends its own entry on entering a window, as modes.nvim does, has to skip
the `changeset` filetype or its entry wins. mini.cursorword is off in the sidebar, as the
hidden cursor would still underline whatever word a click leaves it on.

A line belongs to the deepest symbol row whose body holds it, else to the file's
`Other changes` row when one of its hunks does, else to the file row. A file shown in
several sections answers from the copy with the deeper match. On a tie in depth, a changed
row beats an unchanged ancestor, so a comment-only class holding a changed method answers
from its Docs row rather than its bare copy. Any other tie, and a line no copy matches, go
to the path section's copy. When the row is off screen — folded, filtered, or inside a
compressed chain — its nearest visible ancestor wears the highlight instead.

Focusing the sidebar, by `:Changeset`, a click or `<C-w>`, puts its cursor on that same
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

### The review comment window opens under the line it is about

A review comment is written in a float under the buffer line it is about, or the last line
of a range, laid in line with the code: the lines after it move down to make room, so the
line being discussed stays directly above the window and the code after it directly below,
all readable while the review comment is drafted:

```text
local function greet(name)
╭ Review comment · line 3 ───────────────────────────────────────────────╮
│**bold** and a list:                                                    │
│- item                                                                  │
│                                                                        │
│                                                                        │
│                                                                        │
│                                                                        │
╰ kept until :Changeset submit ────────────────────────────── <C-CR> save ╯
  return "hello " .. name
end
```

Neovim has no window inside a buffer's text, so blank virtual lines (`virt_lines`) as tall
as the float and its border make the room, and the float lies on them. It is attached to
the window (`relative = "win"`, `bufpos`), so it moves with its line as the source
scrolls, and `row` counts past every screen row of a wrapped line. Opening scrolls the
source the least that shows the line with the room under it. A floating source has nothing
to scroll past, so it grows by the room instead and shrinks back afterwards. While the row under the line is scrolled out of the source the float hides,
and entering it scrolls the line back into view. Edits to the source never move the room
off the line: it stays on the line number, as the float does.

Its width is the room right of the source window's gutter, less the border, between 20
and 72 columns, re-fitted as the source is resized: a review comment is prose, and prose
reads at a short measure, while 20 keeps a cramped split usable. Six rows are room for a
paragraph without pushing the code after it far away; a longer review comment scrolls.
The buffer is `markdown`, so the formatting is highlighted as it is typed, and it
wraps at word boundaries. `style = "minimal"` drops the number column and sign column,
which describe a file this buffer is not. The filetype is set once the float is open, so a
user's markdown `FileType` settings, such as `spell`, reach it and win over the style.

The border does the labelling, as the kind menu's does. The title names the line or lines.
The footer says where a save goes and, at its right end, the first `review_comment.save`
key in Neovim's own notation (`<C-CR> save`), since every review comment ends with that key
and it is the one nobody should have to look up. A float takes one `footer_pos`, so both
share a left footer padded with border to the window's width; a window too narrow for both
drops the key. The other keys stay off the border: `?` lists them all. However a new
review comment's text goes, except the close a taken save makes, it is kept: `q` in
normal mode, `<S-Esc>` in either mode where the terminal sends it, `:q`,
`<C-w>c`, an `:e` in the float, quitting Neovim. One `BufUnload` hook on the window's buffer catches
them all, since the buffer goes with the window (`bufhidden=wipe`), and takes the room
under the line with it. Plain `<Esc>` still
only leaves insert mode, so a habitual `<Esc>` on the way to normal mode never closes it.
A save of only whitespace is no save: it closes the window like `q`, so the blank text
reaches the same hook and the caller discards it, never storing it.

### Dialogs ask in floats of changeset's own

```text
╭ Delete the review comment ──────────────╮
│                                         │
│  lua/changeset/git.lua:12-13            │
│  ▎ Why read the reflog rather than the  │
│  ▎ config?                              │
│                                         │
│                     Keep      Delete    │
│                                         │
╰─────────────────────────────────────────╯

╭ Submit the review ─────────────────────────────────────╮
│▌ 1  ● claude   idle     󰎤 parser  Fix the parser       │
│  2  ● codex    working  󰎧 tests   run the suite        │
│  3  ● claude   blocked  answer its prompt first        │
╰ <CR> or 1-3 submit  q cancel ──────────────────────────╯
```

The question before a deletion and the choice of agent for `:Changeset submit` are floats
`changeset.dialog` draws, not `vim.ui.select`: a picker such as mini.pick turns a question
into a fuzzy list under a prompt, which reads as a search rather than a decision. Neovim
0.12's experimental `ui2` gives plugins no dialog to build on, as it only redraws
`confirm()`, `input()` and messages, so the dialogs use plain float features and look the
same with it on or off. Their `zindex`, 150, is above other floats and the popup menu and
below the command line and `ui2`'s message windows, so a message raised while one is open
still shows.

Both are centred on the editor, sized to their content and modal, in `NormalFloat` with a
rounded border, as the kind menu and the review comment window are. The border does the
labelling: the title names the action in the words its button and the notification after
it use, as in "Delete the review comment", Delete, "deleted the review comment".

The question names what goes rather than asking yes or no, so the user recognises it before
it goes. Deleting a review comment quotes it: its place as the Comments row writes it, cut
from the front in a narrow editor since the file name matters most, then up to four lines
of its body behind the marks' `▎` in their green. Abandoning counts what goes. Two buttons
sit bottom right, safe first: Keep, then the verb in `DiagnosticError`'s colour. Each is a
padded pill cut from the editor's own background, where the theme keeps text and its error
colour legible; where the float shares that background, the float's is shaded toward its
text instead. The focused one is reversed and bold, the only bold in a dialog, in the
accent the sidebar's selection uses, or in the error colour for the verb. Focus starts on
Keep, so an Enter typed ahead keeps. Each label's first letter is underlined and presses
it, Keep's as `k` and the verb's only with Shift, `D` or `A`. The verb's letter without
Shift does nothing, silently. `dd` is how a Vim hand deletes a line, and on a Comments row
its second `d` arrives before the question draws: unshifted, it would delete the review
comment unseen, skipping the look the quote exists for.

The picker lines its rows up in columns, a row's last cell running free. Each row leads with
its number, which a digit presses, and a `●` in its status's colour: idle and done in
`DiagnosticOk`, working in `DiagnosticWarn`, blocked in `DiagnosticError`, anything else in
the meta colour. The focused row wears the sidebar's selection tint, mixed over the float's
background rather than Normal's, since no colorscheme checked paints the two alike, and a
`▌` in the accent at its left edge, where a list is read from. An agent at a permission
prompt is listed dimmed, saying why, and can't be picked.

The cursor is hidden while a dialog has focus: the focus is drawn, and the cursor would only
cover it. It hides through a `'guicursor'` entry of its own, `n:ChangesetNoCursor`, apart
from the sidebar's `n-v` one, so neither removes the other's. Leaving the window any other
way cancels. Every close gives focus back to the window the dialog opened from before the
answer runs, so whatever the answer opens or focuses is not undone by the close.

A dialog is modal, and three things hold it so:

- **Its window keeps its buffer**, through `winfixbuf`. The float takes its opener's
  jumplist, so a reflexive `<C-o>` would otherwise leave a file in it, still open, with the
  cursor hidden everywhere and the answer never coming. A buffer forced in anyway, as `:b!`
  can, cancels the dialog as leaving does.
- **One is open at a time.** A second, from a global key pressed inside the first or an
  agent list arriving late, is refused and answers as cancelled: it would take focus, and
  the first's leave would then cancel both. A dialog whose window is gone holds no claim,
  as one closed under `noautocmd` never runs its leave. A cancel that closes behind a
  newer dialog, as when one batch of keys closes one and opens another, leaves focus with
  the newer one.
- **A resized editor fits and centres it again**, with the sums it opened with. Its text
  keeps the wrap it opened with.

### Stats

Right-aligned virtual text, `+N` in `GitSignsAdd`, `-N` in `GitSignsDelete`. Numbers, not
a bar — a bar would be decoration competing with the rail, and the rail already won.

A symbol's `+N` counts only the changed lines falling inside its own range, so a hunk
running across two symbols gives each one its own share and the lines in the gap between
them to neither. A file's `+N` is git's count for the whole file and can therefore exceed
the sum of its symbols'. A file split across its path section, Tests and Docs shows its own
share on each copy, and the shares sum to git's count. Docs takes the lines of its
comment-only units, Tests its test lines less any Docs units inside them, and the path
copy the rest. Removed lines have no position in the new file to split on, so a hunk's
`-N` goes wholly to the first symbol it reaches.

### Header

```text
  origin/jt/exc-1200-stacked-parent…     #412
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
`%<`, which keeps the tail. The branch's open PR sits at the right edge, one blank cell in,
while the tree is measured against the branch that PR merges into.

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

### Review comments in their files

```text
  7 󰍩 local function find(root)        ● cache this per root?
  8 󰍩 if not ok then                   ● say which ref failed
  9 ▎   return nil
 10 󰍩 end                              ● ok here ● and simplify
```

Each review comment is marked in its file's buffer by three things. Its line numbers, every
line of a range, turn `ChangesetReviewComment`: `DiagnosticOk`'s green, bold, a deliberate
divergence from § Visual system's vocabulary rule, since the config has no "all is well"
green and `GitSignsAdd`, the green it does use, already means added lines. The number
column is the one margin gitsigns leaves alone, so the numbers sit beside the `▎` without
competing for its cell, and lighting every number of a range shows how far the cursor can
be and still reach that review comment. With `'number'` and `'relativenumber'` both off
there is no such column, and a range shows only its first line's bubble and circle. At the
end of its first line sits `●`, the config's own current-item mark, in the same green,
followed by the body's first line in `ChangesetReviewCommentBody`, `Comment` and italic:
the § Three levels "not content" idiom, since the body is not the file's text. Two review
comments on one line show as two circles, each with its own body, in the order the store
lists them; their ranges' number colours merge.

The marks are drawn in every loaded buffer of a repository with review comments, sidebar
or not, once changeset is loaded: `plugin/changeset.lua` requires nothing, so a session
that never uses changeset marks nothing. They are redrawn after every write to the store,
as a file is read and as it is written, and a redraw reads the store once for each
repository it draws. Stored line numbers never move with edits. The marks are extmarks, so
they follow unsaved edits, and writing the file snaps them back to the stored numbers, which
then sit on whatever lines now hold them. Until then the verbs that act by line refuse in
the modified buffer, since the marks and the stored lines disagree.

The third mark, a comment bubble `󰍩` in the same group, takes the sign column on the first
line, and it is the one that does compete for a cell. It is left at the default extmark
priority, 4096, far above gitsigns' 6 and a diagnostic's 10 and up, so it covers whatever
sign the line had: while a review comment is open, that is what the line is about. It goes
on the first line only. The lit numbers already show how far a range reaches, and a
statuscolumn that draws the bubble in its fold column would lose every fold marker down a
long range. A line gets one bubble however many review comments start on it, so the
bubbles never stack. Under `'signcolumn'` `auto` they never widen the column, but the first
bubble in a buffer with no other sign opens the column and shifts the text two cells.
`auto:2` and wider still widen by one where a bubble shares its line with another sign.
`yes` holds the text still.

A statuscolumn that draws the bubble elsewhere, such as in its fold column, can't leave it
out of `%s`, which draws every plugin's signs or none, so the bubble would show twice and
the second copy would hide the line's `▎`. `review_comment.sign = false` keeps it out of
the sign column. The mark stays, with `sign_hl_group` but no `sign_text`, which takes no
cell and draws nothing. `require("changeset").bubble()` answers from that mark, so it
answers whatever the option is, and from the buffer's marks alone, since a statuscolumn
asks on every screen row of every redraw. The bubbles live in a namespace of their own,
`changeset.review_comment_signs`, so it finds a line's with one lookup. `README.md` states
the function as the contract rather than the namespace's fields, which leaves how a mark
carries its bubble free to change.

No icon plugin has a category to ask for a comment, so, like the header's branch glyph,
the bubble is borrowed rather than looked up: `󰍩` is nerd-font Material `message-text`, the
glyph the config's which-key spec gives its messages entry. Without a nerd font it draws
as a missing-glyph box, as the header's glyphs do.

### Hover answers with the review comments on a line

```markdown
**Review comment · lines 8-10**

cache this per root?

---

**Review comment · line 9**

and say which ref failed
```

Hover is answered by an in-process language server whose client is named `changeset`, not
by wrapping `vim.lsp.buf.hover()` or mapping `K`. Users bind hover to `K`, to helpers built
on `vim.lsp.buf_request_all`, or to a plugin, and every one of them asks LSP, so a client is
the one place all of them hear from. It also answers on a line, or in a file, that no other
server has hover for. Where its answer lands among other servers' is the hover UI's
business: stock hover stacks each server's answer under a `# <name>` header. The name is
what `README.md` gives a hover UI to sort on, so it is part of the contract.

The answer is every review comment whose lines take in the cursor's line, in the order the
marks draw them, each a bold heading in the review comment window's
title vocabulary and the body as written, with `---` between them, the separator stock hover
puts between servers. A line with none gets `nil`. It is read from the store at request time, so it
follows the marks without re-attaching, with the same caveat about edited files.

A buffer is attached whenever a redraw marks it, and detached by the redraw that leaves it
unmarked: its last review comment going, or the review abandoned. So only a file with something to say has the client, for as
long as its bubble shows: a file buffer only, never a `buftype` one, and one client per
repository root. Neovim keeps a client with no buffer running, still listed by
`:checkhealth vim.lsp`, so the detach that leaves none stops it, and the next mark starts a
fresh one. The server answers each request at once, reports it no longer pending so the
client does not list it as pending forever, and answers an unknown method with
`MethodNotFound`. It reports its exit on `exit` and on a forced stop alike, since a client
only cleans up once told, and an in-process server has no process to die.

Attaching is visible to the rest of Neovim:

- `LspAttach` fires on those buffers, and `LspDetach` as their marks go, so a user's
  handlers run there: keymaps one sets unconditionally, such as `gd`, reach a markdown file
  no other server attaches to, until its `LspDetach` handler takes them back.
- `:checkhealth vim.lsp` lists `changeset` with its command as a function while a buffer
  is attached, and statusline LSP components list it on those buffers.
- It advertises only `hoverProvider` and no `textDocumentSync`, so nothing sends it
  `didOpen` or `didChange`, and formatting, diagnostics, code actions, completion,
  symbols, inlay hints and semantic tokens pass it over. The symbol walk's wait for a server
  ends only on a client that lists symbols, so `changeset` attaching first, as it does when
  a review comment is written mid-wait, never marks a file as having no server.
- In a file no other server attaches to, Neovim maps `K` to `vim.lsp.buf.hover()` unless
  `'keywordprg'` or a `K` mapping is set, so while it is attached `K` on a line with
  nothing says `No information available` instead of running `'keywordprg'`, and `grr`
  reports that no server supports references where it was silent. Format, code actions and
  definition say what they say with no client. Detaching gives both back. Neovim 0.12 never
  unmaps its own `K`, on a detach or an exit, so the detach unmaps it once no server left on
  the buffer has hover; with no client left, `grr` is silent again.

### Submitting hands the review to an agent

`:Changeset submit` turns the review into text and pastes it into an AI agent's prompt in
another pane of the same herdr workspace, through `changeset.herdr`. Each review comment
becomes a block: its `path:line` or `path:first-last`, its lines fenced in the file's
filetype, and its body. The lines are read as they are now, from the buffer when the file
is loaded, so the agent sees what the comment was written against, unsaved edits included.
Blocks go by path, then line, a blank line apart, the way the Comments section orders them.
A block whose lines can't be read, its file gone or its range past the end, keeps its place
and body and drops the fence rather than quoting the wrong lines.

The paste is left unsent and the agent's pane focused. The review is the start of a
conversation, not all of it: the user adds what the comments don't say, such as what to
fix first, and presses Enter. With one agent in the workspace it goes there; with several,
the agent picker of § Dialogs asks, so the user never routes a review to an agent they can't
see.

The review comments are deleted once the paste lands, because the agent now holds them and
a later submit would paste them twice. Only the ones pasted go: one written, or edited, while
the picker was open stays for the next review. A refusal keeps them all. An agent at a
permission prompt refuses, since herdr would drop the paste there without a word, and a
review that vanished into a prompt would read as delivered. The picker lists one but won't
pick it, and delivery checks again, since a pick can be minutes old. A cancelled pick says
nothing.

### The Comments section lists what you wrote

```text
 󰍩  Comments            3 comments
 ● 󰢱 reviewing.lua:42  say which ref failed
 ● 󰂺 README.md:12  fix the typo
 ● 󰢱 view.lua:7-9  cache this?

 󰴉  Implementation      2 files      +12 -3
```

The marks in the files show a review comment where you read, but finding the ones you
wrote means visiting every file. So the sidebar lists them in a section of their own, first,
above Implementation: they are what you come back to. It is a section of another kind. It
classifies no file, so its rows are not file rows, and it holds every review comment of the
tree's repository, one row each, by path and then line.

Its header follows § Sections: an icon, the label, and a count of its rows in the meta
colour, taken before any filter. The icon is the marks' bubble, `󰍩`, borrowed as they
borrow it and drawn in `ChangesetReviewComment`. It carries no `+N -N`: a review comment
changes no line, so a stat there would mean nothing.

A row speaks the marks' language. Their circle, `●` in `ChangesetReviewComment`, stands in
the rail's column. The file's icon follows, then its name and the line or range. The
directory is left out, as the preview band and `y` both carry the whole path. The body's
first line comes last, in `ChangesetReviewCommentBody` like the marks' body, clipped to fit.

The section is read from the store each time the sidebar draws, so it needs no PR and no
wait, and is left out while it lists nothing. It follows every write to the store by
redrawing alone; the diff is never read again for it. A redraw keeps what each row was last
drawn from, so moving the cursor reads nothing from disk. A row's id is its path and range,
so a restored session lands on it as soon as the diff is in.

Being no file, its rows stay out of what counts files. The footer names no file on one,
"you are here" never lands on one, `H` and `L` leave its rows and its fold alone, and the
picker lists none: the picker lists changes, and a review comment is not one. They are rows
for everything else. `h` and `l` fold the section, remembered like any other, `]]` and `[[`
stop on its header, a filter matches a row by its path, moving onto one previews its line,
`y` copies its `path:line`, and opening one marks it as the pick.

A row is for finding what you wrote, so its keys act on that. `<CR>` and the split and tab
keys jump to its line, then open it editable in the review comment window, its title and
keys' descriptions saying edit and update. `d` asks first, in the question of § Dialogs that
`:Changeset abandon` uses too, then deletes it.

### Footer

```text
 Changeset  file 3 of 12  󰈲 sess           <CR> open  f filter  F kinds  ? all keys
```

The sidebar's own `statusline`. With `laststatus=3` a window's own statusline is drawn
only while that window has focus, so it takes the global bar's place exactly when the
sidebar's keys are worth naming, and hands it back the moment you leave. The badge is the
header glyph's `Directory` colour, reversed, standing where the mode badge would. The
position counts the files on screen — a folded section's files are not — and names no file
while the cursor is on a section header or a comment row. A file shown in more than one section counts
once, at its first row. The filter in force is named, since once its prompt closes the lit
matches are the only other trace of it. Only four actions are offered, each under the key
`keymaps` gives it and left out when set to `false` — `?` lists the rest.

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
row that names no destination — a file, an orphan hunk — reads `<CR> to open` instead —
or whatever `keymaps.jump` is, and nothing when it is `false`. `%<` sits before the path,
so a window too narrow for all three gives up the part the sidebar is already showing. The
badge is `reverse`d
rather than given a looked-up background, so it pairs the theme's warning colour with
whatever the window is actually drawn on and survives a theme that leaves `Normal`
transparent. The band behind it is `CursorLine`'s background — the faintest tint every
colorscheme gives a window to say "this is the thing you are on", quiet enough to sit over
a file rather than in front of it — and it runs the full width, which is why a band rather
than a border: a split cannot have one, and the sidebar already speaks winbar. The icon
gets a group of its own recoloured onto that background, because an icon plugin's group
carries a foreground only and the glyph would otherwise punch the window's own background
through the band.

The band goes the moment the window stops previewing — `q` puts it back with the buffer,
and a commit clears it — `<CR>`, or simply entering the window — because a file you chose
is not on loan. The window the cursor is in never wears it at all: a `]h` pressed there
previews without a band, and one that came along with a buffer or a split comes off the
moment that window takes focus or a buffer.

### `<C-g>n` opens where `]h` previews

`keymaps.next` / `keymaps.prev` (`]h` / `[h`) and `<C-g>n` / `<C-g>p` step over the same
rows, but they answer different questions. `]h` asks "what's next?" and only previews, so
the window wears a band and `q` takes it back. `<C-g>n` means "take me there". It opens the
row as `<CR>` does, adding a jumplist entry, so walking a branch feels like moving through
your own window rather than through a preview. It keeps focus where you pressed it. It
skips a Comments row's review comment window, because a float on every step would break
the walk. It stops at the ends rather than wrapping, so a run of `.` can't loop.

Every press has to move you, or it reads as a dropped key. So `<C-g>n` counts places, not
rows: it steps on past any row that would open the path and line the target window
already stands on. A file's row, its group row and the group's first change often all do.
A press made before the tree is ready isn't dropped either. It waits, and presses made
meanwhile add up. It is taken on the `diff` or `symbols` event that redraws the sidebar,
once the file you are in is decided. Before that, the file's rows are placeholders, and a
step among them can go backwards. It is dropped when the sidebar closes, when the diff
fails, or when you are no longer in the window and buffer you pressed it in, so it never
pulls you back from where you went.

A step from the sidebar hands focus back to it. That return skips two things once: the
landing on your row, which would undo the step, and the preview of the row just opened,
which would put a band over the opened line. A one-shot skip of each, rather than
`'eventignore'`, lets the file window's leave events and other plugins' handlers fire as
usual.

The four walking keys are dot-repeatable because they are exactly the motion you press
again and again. `.` after them repeats the step and not your last edit, which only works
because they leave nothing for `.` to repeat otherwise. The operator is `g@l` after an
`<Esc>`. The `<Esc>` drops the typed count, and the count goes into the `'operatorfunc'`
lambda instead. That is a choice: `.` repeats the first count, and a count given to `.`
itself is lost.

`<C-g>c` is a prefix of `<C-g>cc`, `<C-g>cn` and `<C-g>cp`. On its own, after
`'timeoutlen'`, it would fall through to Select mode or a pending `c`. So when changeset
maps `<C-g>cc`, it maps `<C-g>c` to comment too.

### Empty and failed states direct, never apologise

| Situation | Text |
| --- | --- |
| On the default branch | `On trunk — nothing to compare. Switch to a branch to see its changes.` |
| Branch with no diff | `<branch> matches origin/trunk. Nothing changed yet.` |
| Symbols still resolving | `⋯ reading symbols` under the file row |
| No LSP for a file | nothing special — the file renders with its orphan-hunk group |

The two sentences wrap at the sidebar's edge, which no row does: a row is trimmed to fit.

What an empty subtree means is carried by the row, not inferred from it. A file row
carries its read status — `reading`, `done`, or `skipped` for a deleted or Generated file
— and only a `reading` row gets the placeholder. That keeps three cases apart which all
render childless: still waiting, a skipped file, and a file with genuinely nothing to show
inside it — a 100% rename, a binary change.

## What a branch is compared against

A branch's changes are what it added to the branch it was created from, so that branch,
its parent, is the base. A stacked branch then shows only its own changes from the first
build, before gh answers and whether or not a PR exists. A PR's target is known only once
gh answers, and a branch without a PR has none, so without the parent every stacked
branch would be measured against `origin/HEAD`, the default branch.

git keeps no parent in config: a branch's upstream is its own remote counterpart, and
worktrunk records none. The one record is the creation entry of the branch's reflog,
`branch: Created from <source>`, which names the source as the command was given it.
`Git.parent` resolves that source and drops its remote, so `origin/parent` and
`refs/remotes/origin/parent` both name `parent`.

`git switch -c feature` and `git checkout -b feature` record only `HEAD`. Resolving it
would name the branch checked out now, so the parent is read instead from the checkout
they made, `checkout: moving from parent to feature`, the oldest such entry in the
worktree's HEAD reflog. That entry then passes the same rules as a recorded source.

Any other source names no parent and the base stays as it was, the PR's target else the
default branch:

- A commit, and a detached `HEAD`, whose checkout entry names a commit.
- Another worktree's `HEAD`, as `git worktree add -b feature <path>` records. The new
  worktree's HEAD reflog holds no checkout to `feature`.
- The branch's own remote counterpart, which `git switch feature`, `gh pr checkout` and
  checking out a remote branch in a new worktree write. Taken as the parent, it would
  diff someone else's PR against itself.
- The default branch, so a branch cut from it still moves to its PR's target when that
  is another branch.
- A parent since deleted, and reflogs whose entries for the branch's creation have
  expired or are missing.

The parent is measured by `Git.merge_base`'s rules, origin's ref preferred when both it
and the local branch hold the fork point, so a parent that was never pushed works too.

A parent is stale once the default branch's fork point descends from the parent's, and
the default branch's rule applies instead. That is a branch rebased onto the default branch
past its parent, as after the parent was squash-merged and kept: measured from the parent,
the default branch's newer commits would count as the branch's own. A normal stack keeps
its parent, since there the parent's fork point descends from the default branch's. So
does a parent whose fork point is the default branch's, as before it has commits of its
own.

The PR stays on the tree only while its target is the parent, or while HEAD forks from
its target at the parent's fork point, as it does once the parent is merged into the
target with a merge commit, or while the parent has no commits of its own. The header
names the PR as the diff the sidebar shows, and the two match only when both are measured
from the same commit. A branch whose PR targets a branch forking elsewhere keeps its
parent and loses the PR's number. Retargeting the PR, or deleting a parent that has
merged, brings it back.

A parent guessed from the refs, such as the branch whose tip is nearest, isn't tried. It
costs a merge-base per branch on every build, and any branch sharing that history can
claim it.

## What it remembers

The tree is built the first time something asks for it — `:Changeset`, the picker
(`require("changeset.pick").pick()`), or a restored session refilling the sidebar — for
the current buffer's repository: the fork point is measured at once, the diff and symbols
in the background. Reading symbols loads each changed file the cache can't answer,
Generated ones aside, so those buffers and their language servers arrive with that first
ask, and a session that never asks starts none. The picker waits a moment for the diff,
which it has no way to fill in behind. The sidebar opens at once: a tree still waiting on
its first diff opens blank rather than claiming nothing changed. Closing the sidebar lets
go of the window only, and opening it again draws the tree it kept and refreshes its diff
in the background. The tree is rebuilt for a different repository, fork point or branch,
and a build that finds no fork point keeps the tree it had. The tree knows nothing of the
sidebar. The first time the sidebar reads a replaced tree, it starts a fresh View and
Position: the repository's folds and opened chains carry over, and hidden kinds come back
from what is saved for the new branch.

Once built, the tree re-reads the diff whenever the files it diffs can have moved, whether
or not the sidebar is showing: after a write, when a buffer is reloaded because its file
changed outside Neovim, when Neovim regains focus, and when gitsigns sees HEAD move. Its
per-buffer `GitSignsUpdate` is not one of them. It fires on every attach and every hunk
change while typing, none of which moves a diff git reads from disk, and the symbol walk's
own buffer loads would fire it too, restarting the walk they came from. Any of these that
finds HEAD on another branch with a fork point rebuilds the tree for that branch instead,
so the header follows a switch made outside the sidebar. A detached HEAD, as in a stopped rebase or a bisect, only refreshes.

Asking a language server about every changed file is what makes a cold build slow: 28
files took about nine seconds in the config the plugin was extracted from, and the tree
fills a row at a time while it waits. Symbols are cached per file instead, stamped with
the file's size and mtime and the base it was diffed against, so the next build asks a
server only about what has changed since — the same tree comes back complete in under
300ms, which is the `git diff` and nothing else.

The cache is one JSON file per repo under `stdpath("cache")/changeset/`, holding only the
fields the tree reads from a symbol. Every refresh narrows it to the files the current diff
touches, so it stays the size of a branch rather than growing with every branch ever
reviewed, and losing it costs one slow build. An entry also records which symbols the
syntax marked as tests, and each side's comment, directive and blank lines, so a cached file
is never parsed again and its base is never read again. The file name carries a
format number, bumped whenever an entry gains a field, because an older entry's stamp would
otherwise still match. Folds — a section's as well as a file's — are remembered per
repository for as long as Neovim is running, so reopening looks like you left it; a restart
starts expanded, except Generated, which starts folded. Per repository because a row is
identified by a repo-relative path, which two checkouts can easily both have.

## Hidden kinds

Which symbol kinds are hidden is not a setting: it is a choice made in the menu and
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

## Behaviour that is easy to get wrong

- **An edit closed without a save drops the edit.** The review comment keeps its saved
  text, and a changed one says so. Closing it with only whitespace, by a save key or any
  other close, asks to delete it instead, since an empty review comment is never kept.
- **A saved review comment leaves insert mode before the window closes.** The save keys
  are pressed while typing and the answer comes later. `stopinsert` only takes effect on
  the next loop iteration, so the window closes on the float's own `InsertLeave`; closing
  sooner ends insert mode in the user's file, nudging its cursor left and firing its
  `InsertLeave`.
- **`<C-s>` saves alongside `<C-CR>`** because many terminals never send `<C-CR>`.
- **A float is never clipped to the window it is anchored to.** Scrolled off its line, the
  review comment window would sit at the source's edge over other text, or past it over
  the status line and the next window, so it hides until the row under its line is back.
- **Neovim scrolls any window back to its cursor, current or not.** Scrolling the source
  to show the review comment window's line moves the source's cursor to that line too, or
  the old view comes straight back.
- **`WinScrolled` names only the first window that changed.** The review comment window
  re-places itself on every one, whichever window it names, or a resize that changed
  another window first would leave it misplaced.
- **Replacing every line of a buffer carries its extmarks to the end.** A source redrawn
  that way would carry the review comment window's room with it, so the window puts its
  room back under its line after every change to the source.
- **A file cached before its parser was installed keeps just the name rules** until it
  next changes: its entry was read without the syntax layer, and its stamp still matches.
  Its comment lines are missing too, so its comment-only changes stay out of Docs. A moved
  base re-reads every file, base side included.
- **Preview is non-destructive.** `j`/`k` swap a window's buffer and cursor for real, but
  `q` or closing the sidebar with the toggle puts back every window a preview borrowed,
  buffer *and* cursor. Only a commit — `<CR>` and its split variants, or entering the
  previewed window — keeps the file there and writes a jumplist entry, sending `<C-o>`
  back to where the window stood before the sidebar opened rather than to the last preview
  — previewing must not write one, or `<C-o>` becomes one entry per keypress. Entering
  counts only as an arrival: a preview `]h` made in the window the cursor was already in
  stays a preview however focus leaves and returns, until `<CR>` or `q`.
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
  same reason: `BufRead` is what it attaches on. Its own `BufEnter` is run explicitly too,
  and only its own: gitsigns puts off signing a buffer it attached off screen — every file
  the symbol walk loaded — until that buffer is entered, which a preview never does. The
  review comment marks' `BufReadPost` is run explicitly for the same reason, so a
  previewed file shows its marks.
- **`?` documents the sidebar, not its buffer.** A buffer collects mappings from whoever
  wants one — a blanket `FileType` autocmd elsewhere in a user's config is all it takes —
  and those keys are not this sidebar's interface. The keys it sets are recorded as it
  sets them, and which-key is handed a throwaway buffer carrying only those, since it
  describes whatever a buffer maps and takes no say in which. The callbacks travel across
  with the keys, so pressing one from inside the popup still works. The step keys
  (`keymaps.next` / `keymaps.prev`, unbound by default) are global rather than
  buffer-local, so when set they are looked up by name and added to that buffer, or they
  would be the two keys the reference never mentions.
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
  tests or comments, or a filter kept only one copy — the cursor moves to the first file
  row with that path.
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
  comes back with the symbol, and the file's comment lines come back with its symbols.
- **Stamp a file before asking about it, not after.** A file edited while its symbols are
  being read has to fail the freshness check next time; stamping afterwards would file
  the answer under the content that replaced it. The same stamp is why an answer is filed
  even after a newer refresh has replaced the one that asked: it still describes what the
  server read, so a refresh never throws away a walk's progress.
- **Only an answer is cached.** A server that never attached, and a file whose buffer held
  unwritten edits when it was read, are both left out: a stamp taken off the file on disk
  cannot describe either, and either one filed as fresh would outlive the edit that made
  it wrong — across restarts, until the file next moves. A file no server answers for,
  with unwritten edits in its buffer, has its comment lines left out the same way until it
  is written.
- **No answer is remembered, but only in memory.** A file no server answers for — `go.sum`,
  a `Makefile` — is not asked about again on every refresh, each of which would wait out
  the attach timeout under a `reading symbols` row, and every write refreshes the tree.
  The file is asked about again once it moves, or once a server that lists symbols
  attaches to it, which is how a slow or newly installed server still gets heard. Its
  comment lines live in memory too, so after a restart its first build reads its base and
  parses it again.
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
