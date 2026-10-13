# Dependency rules

These rules apply to a change to the plugins and tools that the specs and the type check
load, and to the treesitter parsers the specs parse with.

## Bumping a pin

The `pins` table in `tests/support/deps.lua` maps each dependency to a source and a full
commit SHA. `mise run deps` checks each one out under `.tests/deps/`, and every task that
needs a dependency runs it first.

To bump a pin:

1. Edit its SHA in `pins`.
2. Run `mise run deps`.
3. Run `mise run preflight`. Before the suite runs, it rebuilds every parser whose recorded
   revision differs from the `nvim-treesitter` pin.

## Adding a plugin

A new plugin goes into `pins` first. Then prepend it to `rtp` wherever a spec uses it:

```lua
vim.opt.rtp:prepend(require("support.deps").path("<name>"))
```

Add it to `workspace.library` in `.emmyrc.json` and in `tests/.emmyrc.json` as well, so the
type check sees its modules. The tests config writes each path from `$PWD/`, because
emmylua_check checks `tests/` as a workspace of its own and does not resolve `../`.

Both lists hold every Neovim plugin pin but `plenary.nvim`, which no checked file requires,
and whose own luassert annotations would clash with `tests/types/`. `luacov` is not a
Neovim plugin: only the tests config lists it, as its `src` directory, which
`tests/support/coverage.lua` puts on `package.path`.

## Treesitter parsers

The specs parse with the parsers that `tests/support/parsers.lua` lists. `mise run parsers`
compiles them into `.tests/data/nvim/site/parser` with the `nvim-treesitter` pin and the
`tree-sitter` CLI that `mise.toml` pins, so it needs a C compiler. The suite reads only
those parsers, never the ones under your own `stdpath("data")`.

`mise run setup` and `mise run preflight` run it first. `mise run test` only waits for it
when both run together, so a missing parser fails the suite instead of compiling during
pre-push.
