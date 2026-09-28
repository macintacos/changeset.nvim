# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- A sidebar of the files the current branch changed, grouped into Implementation, Tests, Docs,
  Config and Generated, with the symbols each hunk touched nested under its file. It becomes a
  bottom drawer when narrower than `layout.min_file_width`, and sessions restore it.
- A mini.pick picker over the same rows, with a side-by-side preview:
  `require("changeset.pick").pick()` or `MiniPick.registry.changeset`.
- PR Review Mode, which marks the branch's changes in the gutter through gitsigns.
  `pr_review.enabled` turns it on for every branch but the default, and `:Changeset review` then
  toggles it.
- `setup()` options, all optional and validated: each sidebar key under `keymaps` (a key, or
  `false` to unmap it), `layout.min_file_width` and `pr_review.enabled`.
- `:Changeset [toggle|refresh|review]`, with completion; no argument toggles the sidebar.
- `<Plug>(changeset-toggle)`. The plugin maps no key of its own.
- `:checkhealth changeset`: the Neovim 0.12 and `git` requirements, each optional integration,
  and the options in force.
- File icons from mini.icons, falling back to nvim-web-devicons, then to none.
- `Changeset*` highlight groups defined with `default = true`, so a colorscheme or `:highlight`
  overrides them.
