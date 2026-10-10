# API rules

These rules apply to a change to what users call or configure: options, `:Changeset`,
`<Plug>` maps, highlight groups and public functions.

## The user contract

What `README.md` and `doc/changeset.nvim.txt` document is the contract with users' configs.
Changing or removing any of it is a breaking change.

`plugin/changeset.lua` requires no `changeset.*` module when it loads, because those
modules create their autocmds as they load. Its one autocmd of its own is a `User
GitSignsUpdate` that fires once, on the session's first gitsigns update, and hands that
update to `changeset.review`, which starts the watcher keeping buffers on the sidebar's
base. It is what puts the gutter on the branch's base from startup, with or without
`setup()` and the sidebar, and it is why a session without gitsigns loads nothing. Its maps run `<Cmd>Changeset …<CR>`, so a map and the command take
one route through `:Changeset`, with its range. The exceptions are the walking maps,
`next`, `prev`, `next symbol`, `prev symbol`, `next file`, `prev file`, `comment next` and
`comment prev`. They are `g@` operators so that `.` repeats them, and their
`'operatorfunc'` calls `step()` in `lua/changeset/init.lua` and
`next_comment()` / `prev_comment()` in `lua/changeset/reviewing.lua` with the count. So
those functions stay public, and the expr map's callback requires nothing. From the review
comment window the expr map returns `<Cmd>Changeset …<CR>` instead, so it takes the
command's route below.

`:Changeset` asks `changeset.review_comment_window`, only when that module is already
loaded, whether the review comment window is current. If it is, every subcommand goes to
`reviewing.from_window()`: `comment new` saves, `comment del` deletes the comment being written,
`comment draft` keeps it as a draft, and any other closes the window, keeping a draft, then runs from the comment's line in the
source window, or from the sidebar row the window was opened under. That is the one place the rule lives; no verb checks for the window itself.
The plugin records the default `<C-g>` keys it mapped globally in normal mode in
`vim.g.changeset_window_keys`. The window maps each of them again in normal mode on its own
buffer, unless it equals a `review_comment.save` key. It maps them in insert mode too, but
only those `mapcheck()` finds no insert-mode map clashing with when the window opens, so a
map the user makes after startup still counts.

Every subcommand has a `<Plug>` map of its words joined by hyphens, such as
`<Plug>(changeset-comment-new)`. The global keys are defaults under `<C-g>`, plus `]g` and
`[g` for `preview next` and `preview prev`, mapped once startup is done. Each one is skipped when its key is already
mapped in that mode, and all of them are off when `vim.g.changeset_no_default_maps` is
set.

A new command is a `:Changeset` subcommand, never a second user command. It gets a
`<Plug>` map and, when it's a review or walking verb, a mnemonic `<C-g>` default. A
recovery verb, such as `review restore`, gets only its `<Plug>` map. A verb
that walks the tree and opens what it reaches is `next` or `prev`, with what it counts
after it, its key under `<C-g>n`, which which-key names "navigation". A verb that writes, walks,
lists or shows review comments goes under `comment`, its key under `<C-g>c`. One that hands
off or ends the whole review goes under `review`. `:Changeset comment` and `:Changeset review` alone are
errors that name their verbs, not defaults.

`footer()` in `lua/changeset/init.lua` stays public although only the plugin calls it. The
sidebar's statusline evaluates it from a string, `v:lua.require'changeset'.footer()`,
which the type check cannot follow.

`bubble()` in `lua/changeset/init.lua` is public for a user's `'statuscolumn'`, which calls
it on every screen row of every redraw. A draft answers `󰍪` in
`ChangesetReviewCommentDraft`. It answers from the buffer's extmarks alone, never
from the comments file or the tree.

## Adding an option

An option is a field of the `changeset.Config` class in `lua/changeset/config.lua`. A new
one gets:

1. A `---@field` on `changeset.Config`, and on `changeset.Options` too when it is a new
   top-level table.
2. A default in `DEFAULTS`.
3. A check in `validate()`.
4. An entry tagged `changeset-option-<path>` in `doc/changeset.nvim.txt`, and its default in
   the README's `setup()` block.

A module reads an option through `config.get()` when it acts, never when it loads, so a
later `setup()` call reaches it.

## Documenting a name

`tests/docs_spec.lua` fails until `doc/changeset.nvim.txt` tags every option, `:Changeset`
subcommand, `<Plug>` map, default key and highlight group, in the scheme `AGENTS.md` § Keeping
docs current gives. The highlight groups are the `Changeset*` names in
`lua/changeset/highlights.lua`. Add each new name to the README too when it adds a key, a command
or an option.
