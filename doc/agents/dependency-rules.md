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
3. After bumping `nvim-treesitter`, run `mise run parsers`. It rebuilds every parser whose
   recorded revision differs from the new pin's.
4. Run the suite.

## Adding a plugin

A new plugin goes into `pins` first. Then prepend it to `rtp` wherever a spec uses it:

```lua
vim.opt.rtp:prepend(require("support.deps").path("<name>"))
```

Add it to `.luarc.check.json`'s `workspace.library` as well, so the type check sees its
modules. That list holds every pin but `luacov`, which is not a Neovim plugin: its modules
load through `package.path`.

## Treesitter parsers

The specs parse with the parsers that `tests/support/parsers.lua` lists. `mise run parsers`
compiles them into `.tests/data/nvim/site/parser` with the `nvim-treesitter` pin and the
`tree-sitter` CLI that `mise.toml` pins, so it needs a C compiler. The suite reads only
those parsers, never the ones under your own `stdpath("data")`.

`mise run test` does not depend on `parsers`, so a missing parser fails the suite instead
of compiling during pre-push.
