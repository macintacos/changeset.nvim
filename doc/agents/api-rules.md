# API rules

These rules apply to a change to what users call or configure: options, `:Changeset`,
`<Plug>` maps, highlight groups and public functions.

## The user contract

What `README.md` documents is the contract with users' configs. Changing or removing any of
it is a breaking change.

`plugin/changeset.lua` requires no `changeset.*` module when it loads, because those
modules create their autocmds as they load, and a session that never opens the sidebar
should create none. Its maps run `<Cmd>Changeset …<CR>`, so a map and the command take
one route through `:Changeset`, with its range.

Every subcommand has a `<Plug>(changeset-<subcommand>)` map. The global keys are defaults
under `<C-g>`, mapped once startup is done. Each one is skipped when its key is already
mapped in that mode, and all of them are off when `vim.g.changeset_no_default_maps` is
set.

A new command is a `:Changeset` subcommand, never a second user command. It gets a
`<Plug>` map and, when it's a review verb, a mnemonic `<C-g>` default.

`footer()` in `lua/changeset/init.lua` stays public although only the plugin calls it. The
sidebar's statusline evaluates it from a string, `v:lua.require'changeset'.footer()`,
which the type check cannot follow.

`bubble()` in `lua/changeset/init.lua` is public for a user's `'statuscolumn'`, which calls
it on every screen row of every redraw. It answers from the buffer's extmarks alone, never
from the comments file or the tree.

## Adding an option

An option is a field of the `changeset.Config` class in `lua/changeset/config.lua`. A new
one gets:

1. A `---@field` on `changeset.Config`, and on `changeset.Options` too when it is a new
   top-level table.
2. A default in `DEFAULTS`.
3. A check in `validate()`.
4. A row in README `## Options`, followed by `mise run docs`.

A module reads an option through `config.get()` when it acts, never when it loads, so a
later `setup()` call reaches it.

## Documenting a name

`tests/docs_spec.lua` fails until every option, `:Changeset` subcommand, `<Plug>` map and
highlight group appears in the vimdoc. The highlight groups are the `Changeset*` names in
`lua/changeset/render.lua`. Add each new name to the README, then run `mise run docs`.
