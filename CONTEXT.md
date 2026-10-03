# changeset.nvim

A Neovim sidebar mapping what the current branch changed: its files, and the symbols each
hunk touched.

## Language

### Where you stand

**Position**:
Where the user stands relative to the changeset: you are here, the pick, and the landing,
plus a restored position until it settles.
_Avoid_: cursor state, marks

**You are here**:
The row for the file and line the cursor is in, outside the sidebar.
_Avoid_: current row, here row

**Pick**:
The row last opened from the sidebar. Only opening a row moves it.
_Avoid_: last jump, opened row

**Selected**:
The row under the sidebar's cursor while the sidebar has focus.
_Avoid_: cursor row, highlight

**Landing**:
The row focusing the sidebar puts its cursor on, which a rebuild follows deeper until the
user moves the cursor.
_Avoid_: arrival row, focus row

**Restored position**:
A position a saved session recorded, waiting for the rebuilt tree to hold its rows.
_Avoid_: pending restore, saved cursor

### The view

The `keymaps` option names and key descriptions keep the user-facing words expand, collapse
and change.

**View**:
What the sidebar shows of the tree: its folds, opened chains, narrowing and hidden kinds,
and the row on each line. The snapshot `changeset.position` reads is a picture of it, not
the View. `changeset.sidebar_state` makes a fresh View for each new tree, sharing the
repository's folds and opened chains.
_Avoid_: view state, display state

**Open**:
Show more under a row: a shut chain's rows first, else the row's children.
_Avoid_: expand

**Fold**:
Hide a row's children. A file's fold and a section's fold are kept per repository.
_Avoid_: collapse

**Chain**:
A run of single-child symbol rows drawn as one row until opened. Opening a chain is
separate from unfolding.
_Avoid_: compressed row

**Step**:
Move to the next or previous row that is not a section header.
_Avoid_: next change, jump

**Section step**:
Move to the next or previous section header, folded ones included.
_Avoid_: section jump

**Step out**:
Fold the row whose children are showing, else move to its parent.
_Avoid_: collapse or parent

**Narrow**:
Keep only rows matching the query, with their ancestors and children.
_Avoid_: filter state

**Hidden kinds**:
Symbol kinds the tree leaves out, saved for this branch, this repository or everywhere,
narrowest first.
_Avoid_: kind filter

### PR reviews

**Pending review**:
The viewer's unsubmitted GitHub review on the branch's PR, holding review comments until
it is submitted or deleted. GitHub allows one per viewer per PR.
_Avoid_: bare "review", which is PR Review Mode (`lua/changeset/review.lua`); draft review

**Review comment**:
A comment in a pending review, on one line or a range of lines of a file in the PR.
_Avoid_: bare "comment", which is a source-code comment (`changeset.comments`)

**Draft**:
A review comment's text kept on this machine when its window closed without a save GitHub
took. It never reaches GitHub.
_Avoid_: draft review, which is the pending review
