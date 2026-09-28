# changeset.nvim

A Neovim sidebar mapping what the current branch changed: its files, and the symbols each
hunk touched. `README.md` is the user-facing reference and the design record.

## Layout

```text
.
├── .github/             CI (lint + test on push to main and PRs) and Dependabot
├── mise.toml            tools; postinstall registers the hk git hooks
├── mise.lock            exact tool versions (`lockfile = true`)
├── hk.pkl               formatters, linters and git hooks
├── .luarc.check.json    lua-language-server config for `mise run typecheck`
├── selene.toml          selene config for lua/ and plugin/ (tests/selene.toml for specs)
├── vim.yml              selene's vim std: the globals lua/ and plugin/ may read
├── stylua.toml          StyLua config
├── .rumdl.toml          Markdown lint config
├── taplo.toml           TOML format config
├── typos.toml           spell-check config
├── .mise/tasks/         one script per `mise run` task
├── plugin/changeset.lua `:Changeset`, `<Plug>(changeset-toggle)`, session restore, mini.pick registry
├── lua/changeset/
│   ├── init.lua         glue: gathers diff + symbols, owns the tree lifecycle and window state machine
│   ├── attributes.lua   inline test markers the syntax shows, via treesitter
│   ├── buffers.lua      loads the files the sidebar reads
│   ├── cache.lua        symbols kept between builds and restarts
│   ├── config.lua       the user's options: defaults, and what `setup()` made of them
│   ├── diff.lua         runs the branch's git diff and parses it into files and hunks
│   ├── git.lua          git and gh queries that pick the base branch
│   ├── health.lua       `:checkhealth changeset`: requirements, optional integrations, options in force
│   ├── help.lua         the `?` key reference
│   ├── icons.lua        mini.icons → nvim-web-devicons → blank
│   ├── jsonfile.lua     small JSON records under `stdpath`
│   ├── kinds.lua        which LSP symbol kinds are listed, per filetype
│   ├── menu.lua         the symbol-kind popup
│   ├── paths.lua        project root and clipboard copy
│   ├── pick.lua         the rows as a mini.pick picker
│   ├── pick_preview.lua its side-by-side preview
│   ├── prefs.lua        hidden kinds, persisted
│   ├── render.lua       rows → buffer lines + extmarks
│   ├── resolve.lua      asks LSP servers for symbols
│   ├── review.lua       PR Review Mode
│   ├── sections.lua     Implementation/Tests/Docs/Config/Generated classification
│   ├── state.lua        cursor and folds across rebuilds
│   ├── symbols.lua      flattens documentSymbol trees
│   ├── tree.lua         builds the row tree
│   ├── view.lua         filters it
│   └── window.lua       window bookkeeping and layout
├── tests/               specs, minimal_init.lua, support/ fixtures, busted.yml
└── .tests/              gitignored: installed deps, suite data dir, luals logs, coverage output
```

## Tasks

Run `mise trust`, then `mise run setup`, once in each new clone or worktree: mise refuses
to load an untrusted `mise.toml`. Then run `mise run parsers` once: without the parsers it
installs into `.tests/data` (see Treesitter parsers), the specs that parse Rust or
TypeScript fail.

- `mise run setup` — `mise install`; its postinstall hook installs the hk git hooks.
- `mise run deps` — checks out the pinned test dependencies under `.tests/deps`.
- `mise run parsers` — installs the specs' treesitter parsers into `.tests/data`. Depends
  on `deps`.
- `mise run format` — `hk fix --all --no-stage`: every formatter, in write mode.
- `mise run lint` — `hk check --all`: format check, selene, shellcheck, rumdl, taplo,
  pkl, typos, the git checks and `typecheck`. Depends on `deps`.
- `mise run typecheck` — lua-language-server at Warning level with `.luarc.check.json`.
  Depends on `deps`.
- `mise run test [path ...]` — the plenary suite; default `tests/`, or the spec files
  given. Depends on `deps`.
- `mise run coverage` — the suite under luacov; prints line coverage of `lua/`, full
  report in `.tests/luacov/report.out`. Depends on `deps`.
- `mise run preflight` — `lint` + `test`.

The pre-commit hook runs the formatters and linters on staged files; pre-push runs the
type check and the suite. Never bypass them with `--no-verify`.

Run one spec with `mise run test tests/<name>_spec.lua`, not `:PlenaryBustedFile`: that
command takes no options, so its child Neovim skips `tests/minimal_init.lua` and can load
the wrong checkout of the plugin — from a worktree, silently the main one.

## Testing

### Specs

Plenary busted specs, flat in `tests/`, named `<module>_spec.lua` or for a behaviour
(`sidebar_spec.lua`, `band_spec.lua`). Each spec file runs in its own child Neovim under
`tests/minimal_init.lua`, which removes the user config from `rtp`, points
`XDG_STATE_HOME` and `XDG_CACHE_HOME` at temporary directories, scrubs `GIT_*`, and points
global and system git config at `/dev/null`. It points `XDG_DATA_HOME` at `.tests/data`
and drops the editor's data `site` from `runtimepath`.

A test creates its temporary files and repositories itself and removes them after it.
Private functions a spec needs are exposed as `M._name` (see Conventions).

### Fixtures

Specs load these as `require("support.<name>")`:

- `tests/support/deps.lua` — the pins and their installer; `path(name)` locates a
  checkout.
- `tests/support/git.lua` — `git`, `init_repo` and `commit` helpers that take a `cwd`.
- `tests/support/gh.lua` — puts a fake `gh` on `PATH`, driven by `FAKE_GH_PR` and
  `FAKE_GH_DELAY`.
- `tests/support/pr_review.lua` — the PR Review Mode fixture: gitsigns, `changeset.review`
  and a fake gh.
- `tests/support/cursor.lua` — whether `guicursor` hides the cursor.
- `tests/support/coverage.lua` — the luacov hooks.
- `tests/support/parsers.lua` — `data_home`, the suite's data dir that `minimal_init.lua`
  sets, and `site` under it, which it prepends to `rtp`; `nvim -l` on it is the
  `mise run parsers` installer.

Use `support.git` rather than shelling out to git by hand. `chdir` only when the code
under test resolves the repository from the process directory.

### Test dependencies

The `pins` table in `tests/support/deps.lua` maps each plugin to a source and a full
commit SHA. `mise run deps` fetches each into `.tests/deps/<name>`; `test`, `lint`,
`typecheck`, `coverage` and `parsers` depend on it. To bump one, edit its SHA, run
`mise run deps`, then run the suite; after bumping `nvim-treesitter`, run
`mise run parsers` first, which rebuilds every parser whose recorded revision differs
from the new pin's.

A new plugin goes into `pins` first, is prepended on `rtp` where it is used with
`vim.opt.rtp:prepend(require("support.deps").path("<name>"))`, and is added to
`.luarc.check.json`'s `workspace.library` — every pin but luacov, which is no Neovim
plugin: its modules live under `src/` and load through `package.path`.

### Treesitter parsers

The suite needs the `rust`, `typescript` and `tsx` parsers; `tests/attributes_spec.lua`
asserts they load. They live in `.tests/data/nvim/site/parser`, and `mise run parsers`
installs them with the nvim-treesitter pinned in `tests/support/deps.lua` and the
`tree-sitter` CLI pinned in `mise.toml`. The install needs a C compiler. Parsers under
your own `stdpath("data")` are never read. After a pin bump, re-run
`mise run parsers` (see Test dependencies). `test` does not depend on `parsers`: a
missing parser fails the suite rather than compiling during pre-push.

## Conventions

- TDD: a failing spec before any behaviour change.
- Private functions a spec needs are exposed as `M._name` on their module (e.g.
  `M._parse_hunks` in `diff.lua`). They are not public API.
- LuaCATS: a module file opens with a one-line `---` summary; every public function has a
  one-line `---` summary plus `---@param` / `---@return`; types are
  `---@class changeset.<Name>` with `---@field`; a module-level value whose initializer
  does not show its type (a `nil` start, an empty table, a table that must match a class)
  gets `---@type`. `mise run typecheck` checks the annotations that are present, not that
  they are present.
- Comments say why, never what the code does or how it changed.
- Every `nvim_create_autocmd` says what fires it and why, in a `-- Fires:` comment above
  it or in its `desc`. Keymaps are set with a `desc`.
- StyLua formats (2 spaces, 120 columns). A global selene rejects goes in `vim.yml`, or
  in `tests/busted.yml` when only specs use it. A `-- selene: allow(...)` suppression
  sits under a one-line comment giving the reason.

## Public API

`require("changeset").setup(opts)` is optional; zero-config works. Its options are the
`changeset.Config` class in `lua/changeset/config.lua` (`keymaps`,
`layout.min_file_width`, `pr_review.enabled`), deep-merged over `DEFAULTS` and validated;
each call starts again from the defaults. The resolved result is `changeset.Options`, in
the same file. `keymaps.next` / `keymaps.prev` default to `false`, so the sidebar binds no
step keys unless the user sets them. A new option gets its `---@field` (on
`changeset.Options` too when it is a new top-level table), a default in `DEFAULTS`, a
check in `validate()`, and a line in README `## Settings`. A module reads it through
`config.get()` when it acts, never when it loads, so a later `setup()` reaches it.

`plugin/changeset.lua` binds no keys. It defines `<Plug>(changeset-toggle)` and
`:Changeset {toggle|refresh|review}`. It refills the sidebar via `restore()` on
`SessionLoadPost` only when a `changeset://` window is left. On `VimEnter` it sets
`MiniPick.registry.changeset` when mini.pick exists. It requires no `changeset.*` module at
load. `require("changeset")` also exposes
`open`, `close`, `refresh` and `rows()`, which `pick.lua` is built on; its doc block in
`init.lua` says what it returns and how long its first call blocks. `build` and `footer`
serve the plugin's own modules and specs; `footer` stays public because the sidebar's
statusline evaluates `v:lua.require'changeset'.footer()`, a string the type check cannot
follow. Beyond that: `require("changeset.pick").pick()` and
`require("changeset.review").toggle()` / `activate()`. `:Changeset` is the only user command.
`:checkhealth changeset` reports which optional dependencies are missing and the options in
force.

For the options and keys themselves, see README `## Settings` and `## Keymaps`.

## Vendored modules

`git.lua`, `jsonfile.lua`, `paths.lua`, `symbols.lua`, `kinds.lua` and
`pick_preview.lua` began as copies of the author's Neovim config. They are owned by this
repository and not synced with any other copy, so they change as this plugin needs.

## Behaviour that is easy to break

Check a change against
[README.md#behaviour-that-is-easy-to-get-wrong](README.md#behaviour-that-is-easy-to-get-wrong).

## Before a PR

`mise run preflight` stays green on every PR. A PR that changes the layout, a task, a
fixture or the public API updates `AGENTS.md` in the same PR.
