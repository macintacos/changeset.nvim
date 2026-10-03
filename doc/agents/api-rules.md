# API rules

These rules apply to a change to what users call or configure: options, `:Changeset`,
`<Plug>` maps, highlight groups and public functions.

## The user contract

What `README.md` documents is the contract with users' configs. Changing or removing any of
it is a breaking change.

`plugin/changeset.lua` binds no keys, so users choose their own. It requires no
`changeset.*` module when it loads, because those modules create their autocmds as they
load, and a session that never opens the sidebar should create none.

A new command is a `:Changeset` subcommand, never a second user command.

`footer()` in `lua/changeset/init.lua` stays public although only the plugin calls it. The
sidebar's statusline evaluates it from a string, `v:lua.require'changeset'.footer()`,
which the type check cannot follow.

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

`tests/docs_spec.lua` fails until every option, `:Changeset` subcommand and each subcommand's
verbs (`:Changeset pr start`), `<Plug>` map and highlight group appears in the vimdoc. The highlight groups are the `Changeset*` names in
`lua/changeset/render.lua`. Add each new name to the README, then run `mise run docs`.
