# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- A sidebar of the files the current branch changed, grouped into Implementation, Tests, Docs,
  Config and Generated, with the symbols each hunk touched nested under its file. In an editor too
  narrow to leave the files `layout.min_file_width` columns beside it, it opens as a drawer along
  the bottom, and moves between the two as the editor is resized. Sessions restore it.
- A symbol-kind menu (`F`) that hides kinds from the tree, remembered for the branch, the
  repository or everywhere.
- A mini.pick picker over the same changes, with a side-by-side preview, once mini.pick is set up:
  `require("changeset.pick").pick()`, or `MiniPick.registry.changeset` when mini.pick is set up by
  the end of startup.
- PR Review Mode, which marks the branch's changes in the gutter through gitsigns.
  `pr_review.enabled` turns it on for every branch but the default, and `:Changeset review` then
  toggles it.
- `setup()` options, all optional and validated: each sidebar key under `keymaps` (a key, or
  `false` to leave it unbound); `keymaps.next` / `keymaps.prev`, off by default, which step through
  the changes from any window while the sidebar is open; `layout.min_file_width`; and
  `pr_review.enabled`.
- `:Changeset [toggle|refresh|review]`, with completion; no argument toggles the sidebar.
- `<Plug>(changeset-toggle)`. The plugin maps no key of its own.
- `:checkhealth changeset`: the Neovim 0.12 and `git` requirements, each optional integration,
  and the options in force.
- Icons from mini.icons, falling back to nvim-web-devicons (file icons only), then to a blank.
- `Changeset*` highlight groups defined with `default = true`, so a colorscheme or `:highlight`
  overrides them.
