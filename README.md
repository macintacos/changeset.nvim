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

## Health

`:checkhealth changeset` reports the requirements — Neovim 0.12+ and `git` — and each
optional integration the sidebar quietly does without: `gh` for the PR's target branch,
mini.icons or nvim-web-devicons, which-key, mini.pick, gitsigns (required once
`pr_review.enabled` is set), a language server answering `textDocument/documentSymbol`,
and the `rust`, `typescript` and `tsx` treesitter parsers that mark test symbols. It
then prints the options in force. It checks the way the sidebar loads, so a plugin your
manager has held back may load, but it installs nothing, starts no language server and
asks nothing of the network.

## Settings

`require("changeset").setup(opts)` is optional; without it the sidebar binds the keys
below and nothing else. `keymaps` renames any sidebar key, or leaves it unbound with
`false`; `keymaps.next` / `keymaps.prev` bind keys that step through changes from any
window while the sidebar is open, and are off by default. `layout.min_file_width` (80) is
the narrowest the files get beside the sidebar before it moves below them.
`pr_review.enabled` (false) turns on PR Review Mode for every branch but the default;
turning the option back off takes a restart. Each `setup()` call starts again from the
defaults and reaches the sidebar the next time it opens; `changeset.Config` in
`lua/changeset/config.lua` lists every field. While the option is on, `:Changeset review`
switches the mode off for the current branch, or back on; while it is off, the command
errors.

## Keymaps

By default the plugin maps nothing outside the sidebar. Bind the toggle yourself:

```lua
vim.keymap.set("n", "<leader>gp", "<Plug>(changeset-toggle)")
```

`:Changeset` toggles the sidebar too, `:Changeset refresh` rebuilds it and
`:Changeset review` toggles PR Review Mode. A mini.pick set up after startup misses
`:Pick changeset`; register it yourself:

```lua
MiniPick.registry.changeset = function() return require("changeset.pick").pick() end
```

| Key | Where | Does |
| --- | --- | --- |
| `<Plug>(changeset-toggle)` | anywhere | closed → open+focus on the row you are on; open+unfocused → focus on the row you are on; open+focused → close, restore focus |
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
| `?` | sidebar | list the keys the sidebar bound, the step keys included when set: which-key's popup where it is installed, a float where it is not |
| `]h` / `[h` | anywhere, while open | off unless set as `keymaps.next` / `keymaps.prev`; advance the sidebar's selection, previewing as it goes and stepping over section headers — review without focusing the sidebar |
