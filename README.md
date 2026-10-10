# changeset.nvim

A Neovim sidebar that lists the files your branch changed and, under each one, the
functions, classes and methods those changes touched.

![The changeset sidebar previewing a branch's changes as it moves, collapses and expands the tree](.github/demo.gif)

- **Compares against the branch you created yours from**, so a stacked branch shows only
  its own changes, with or without a PR.
- **Previews each change as you move** through the tree, and steps through the changes
  from any window.
- **Keeps review comments** on lines or whole files, then pastes them into an AI agent's
  prompt or copies them as text.
- **Points gitsigns at the sidebar's base**: gitsigns' gutter and inline diff show the whole
  branch, not only uncommitted work.

## Requirements

Neovim 0.12 or newer, and `git`. Everything else is optional:

| Optional                                                                   | Adds                                                                                                  |
| -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| A language server for the file's language                                  | The symbol rows under each file. Without one, a file lists only its changes.                          |
| Treesitter parsers                                                         | Comment-only changes listed under Docs, and Rust and TypeScript tests found by their syntax.          |
| [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim)                | The gutter's base, which marks the whole branch in the gutter, the unified diff, and the change colours. |
| [herdr](https://herdr.dev), a terminal multiplexer for coding agents       | `:Changeset review submit`, which pastes your review into an agent's prompt.                          |
| `gh`                                                                       | The open PR's target as the base, for a branch with no parent.                                        |
| [mini.icons](https://github.com/nvim-mini/mini.icons) or nvim-web-devicons | Icons.                                                                                                |
| [mini.pick](https://github.com/nvim-mini/mini.pick)                        | `:Pick changeset`, a picker over the same changes. Without it, `<C-g>j` uses `vim.ui.select`.         |
| [which-key.nvim](https://github.com/folke/which-key.nvim)                  | `?` opens its popup; version 3 also names the default keys' groups.                                   |

`:checkhealth changeset` shows which of these it finds.

## Installation

Each example also installs the optional plugins from the table above. Drop any you don't want.

With `vim.pack`:

```lua
vim.pack.add({ "https://github.com/macintacos/changeset.nvim" })

-- Optional. Call each one's `setup()` somewhere in your config, such as
-- `require("gitsigns").setup()`.
vim.pack.add({
  "https://github.com/lewis6991/gitsigns.nvim",
  "https://github.com/nvim-mini/mini.icons",
  "https://github.com/nvim-mini/mini.pick",
  "https://github.com/folke/which-key.nvim",
})
```

With lazy.nvim:

```lua
{
  "macintacos/changeset.nvim",
  dependencies = {
    { "lewis6991/gitsigns.nvim", opts = {} },
    { "nvim-mini/mini.icons", opts = {} },
    { "nvim-mini/mini.pick", opts = {} },
    { "folke/which-key.nvim", opts = {} },
  },
}
```

`setup()` is optional. To change an option, call `require("changeset").setup({ … })`, or add
`opts = { … }` to the lazy.nvim spec. The plugin loads lazily by itself: at startup it only
defines `:Changeset` and its keys.

## Quick start

1. On a branch with changes, run `:Changeset` or press `<C-g>g`. The sidebar opens on the
   right.
2. Move with `j` and `k`. Each row previews in the window you came from.
3. Press `<CR>` to open the change, or `<C-v>`, `<C-x>` or `<C-t>` to open it in a split or
   a tab.
4. From any file, `<C-g>nn` and `<C-g>np` open the next and previous change. `]g` and `[g`
   move through the sidebar's rows and preview each without opening it.
5. Press `?` in the sidebar to list its keys, and `q` to close it.

## Reviewing a branch

1. Press `<C-g>cc` on a line or a visual selection. A small markdown window opens under
   it. It works on a row in the sidebar too: a symbol's row comments on the line `<CR>`
   opens, a change's row on its lines, a file's row on the whole file. On a file's first line the comment covers the whole
   file; to comment on that line alone, select it first.
2. Write the comment, then save it with `<C-s>` or `<C-CR>`. Closing the window any other
   way keeps your text as a draft, which submit leaves out. `<C-g>ch` holds a saved comment
   back as a draft, or saves a draft.
3. Walk your comments with `<C-g>cn` and `<C-g>cp`, or list them with `<C-g>cq`.
4. When you're done, `<C-g>s` pastes the saved comments into an AI agent's prompt and takes
   them out of the review; drafts stay. Submit as often as you like: each submit sends only
   what you saved since the last one. This needs Neovim running in a herdr pane. Without
   herdr, `<C-g>y` copies the comments as text and keeps them.
5. If a paste gets lost, `:Changeset review restore` brings a submitted batch back. The branch
   keeps its last 10. `<C-g>a` abandons the review.

Comments belong to the branch they were written on. They follow your edits each time you
write the file, and they stay on this machine. `:help changeset-review-comments` covers
drafts, blocks, hover and the rest.

## Commands and keys

`:Changeset` alone opens or focuses the sidebar, and closes it from inside. Each subcommand
has a `<Plug>(changeset-…)` map named after its words, and these default keys:

| Key                   | `:Changeset …`                  | Does                                                    |
| --------------------- | ------------------------------- | ------------------------------------------------------- |
| `<C-g>g`              | `toggle`                        | Open, focus or close the sidebar                        |
| `<C-g>j`              | `pick`                          | Pick a change to open from a list                       |
| `<C-g>r`              | `refresh`                       | Rebuild the tree                                        |
| `<C-g>nn` / `<C-g>np` | `next` / `prev`                 | Open the next / previous change                         |
| `<C-g>ns` / `<C-g>nS` | `next symbol` / `prev symbol`   | Open the next / previous changed symbol                 |
| `<C-g>nf` / `<C-g>nF` | `next file` / `prev file`       | Open the next / previous changed file                   |
| `]g` / `[g`           | `preview next` / `preview prev` | Preview the next / previous row                         |
| `<C-g>cc`             | `comment new`                   | Comment on the line or selection, or edit the one there |
| `<C-g>cd`             | `comment del`                   | Delete the comment on this line                         |
| `<C-g>ch`             | `comment draft`                 | Hold this line's comment back as a draft, or save it    |
| `<C-g>cn` / `<C-g>cp` | `comment next` / `comment prev` | Jump to the next / previous comment                     |
| `<C-g>cl`             | `comment last`                  | Edit the comment you saved last                         |
| `<C-g>cq`             | `comment list`                  | List the comments in the quickfix list                  |
| `<C-g>ct`             | `comment toggle`                | Show or hide every comment's whole text                 |
| `<C-g>s`              | `review submit`                 | Paste the review into an agent's prompt                 |
| `<C-g>y`              | `review yank`                   | Copy the review as text                                 |
| `<C-g>a`              | `review abandon`                | Delete this branch's comments                           |
|                       | `review restore`                | Bring back a batch of submitted comments                |

- A default key that clashes with one you've mapped is left alone.
- Set `vim.g.changeset_no_default_maps = true` to map none of them, then map the `<Plug>`
  maps you want:

  ```lua
  vim.g.changeset_no_default_maps = true
  vim.keymap.set("n", "<leader>gp", "<Plug>(changeset-toggle)")
  vim.keymap.set({ "n", "x" }, "<leader>c", "<Plug>(changeset-comment-new)")
  ```

- The `<C-g>n` keys, `<C-g>cn` and `<C-g>cp` take a count and repeat with `.`.
- With the default keys mapped, Neovim's own `<C-g>` (file info) waits `'timeoutlen'` for a
  second key.

## Sidebar keys

| Key                         | `keymaps` option                          | Does                                                                    |
| --------------------------- | ----------------------------------------- | ----------------------------------------------------------------------- |
| `<CR>`                      | `jump`                                    | Open the row's change and focus it                                      |
| `<S-CR>`                    | `jump_close`                              | Open it and close the sidebar                                           |
| `<C-v>` / `<C-x>` / `<C-t>` | `jump_vsplit` / `jump_split` / `jump_tab` | Open it in a vertical split / split / tab                               |
| `q`                         | `close`                                   | Close the sidebar                                                       |
| `l` / `h`                   | `expand` / `collapse`                     | Expand / collapse the row, or step out to its parent                    |
| `L` / `H`                   | `expand_all` / `collapse_all`             | Expand / collapse every file                                            |
| `]]` / `[[`                 | `next_section` / `prev_section`           | Move to the next / previous section                                     |
| `f`                         | `filter`                                  | Filter the tree as you type                                             |
| `F`                         | `filter_kinds`                            | Hide symbol kinds, remembered for this branch, repository or everywhere |
| `y`                         | `yank`                                    | Copy the row's `path:line`, or a ranged comment's `path:first-last`     |
| `d`                         | `delete_comment`                          | Delete the review comment on a Comments row                             |
| `R`                         | `refresh`                                 | Rebuild the tree                                                        |
| `?`                         | `help`                                    | List the sidebar's keys                                                 |

Set a key to `false` to leave it unbound. `/` searches the tree.

## What it compares against

The tree shows what changed since your branch left the branch you created it from, else
its open PR's target (found with `gh`), else the default branch. The header names that
base; `:help changeset-base` has the full rules.

## The gutter's base and the unified diff

Both need gitsigns.

- **The gutter's base** makes gitsigns' gutter mark everything the branch changed, not only
  uncommitted work. It is the sidebar's base on every branch, the default branch included,
  from the start of the session, so `setup()` is not needed. `:Gitsigns change_base <rev>`
  still sets a buffer's base by hand, and changeset leaves that buffer alone.
- **The unified diff** turns on once the sidebar has opened: every file shows its removed
  lines inline, above the lines that replaced them. It compares against the same base as
  the gutter. Running `:Gitsigns diffthis unified=true` in a window closes it there and
  keeps it off for the files you open afterwards, until Neovim exits.

## Configuration

`setup()` is optional. These are the defaults:

```lua
require("changeset").setup({
  -- The sidebar's keys, as listed above. Set one to false to leave it unbound.
  keymaps = {
    jump = "<CR>",
    jump_close = "<S-CR>",
    jump_vsplit = "<C-v>",
    jump_split = "<C-x>",
    jump_tab = "<C-t>",
    close = "q",
    expand = "l",
    collapse = "h",
    collapse_all = "H",
    expand_all = "L",
    next_section = "]]",
    prev_section = "[[",
    refresh = "R",
    yank = "y",
    delete_comment = "d",
    help = "?",
    filter_kinds = "F",
    filter = "f",
  },
  layout = {
    -- Below this many columns left for the files, the sidebar opens along the bottom.
    min_file_width = 80,
  },
  review = {
    -- Text pasted above the review, such as a skill to invoke.
    header = "",
    -- Text pasted below the review, such as standing instructions.
    footer = "",
  },
  review_comment = {
    -- The keys that save a review comment, in Insert and Normal mode.
    save = { "<C-CR>", "<C-s>" },
    -- The bubble in the sign column; false when your 'statuscolumn' draws it.
    sign = true,
    -- Start each session showing comments' whole text in blocks.
    blocks = false,
  },
})
```

Each call starts from the defaults. An unknown option is ignored with a warning, and an
invalid value raises an error naming the option. `:help changeset-options` describes each
one, and `:help changeset-highlights` lists the highlight groups.

## Documentation

- `:help changeset.nvim` is the complete reference: every command, key, option and
  highlight group.
- `:checkhealth changeset` reports the requirements, the optional integrations and the
  options in force.
- Contributors: [doc/agents/design.md](doc/agents/design.md) records why the sidebar looks
  and behaves as it does.
