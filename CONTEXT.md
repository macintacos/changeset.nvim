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

### Review comments

**Review comment**:
A note on one line or a range of lines of a file, kept on this machine for the repository's
root until it is deleted, submitted or the review is abandoned.
_Avoid_: bare "comment", which is a source-code comment (`changeset.comments`)

**Draft**:
A review comment kept but not saved: the text of a review comment window closed any way but
a save. Submit and yank leave it out until it is saved.
_Avoid_: unsaved comment, pending comment

**Saved**:
A review comment stored by a save. Only saved review comments are submitted or copied.
_Avoid_: committed, final

**Review**:
Every review comment of a repository. The first one written starts it, and submitting or
`:Changeset review abandon` ends it.
_Avoid_: pending review

**Submit**:
Pasting the review into an AI agent's prompt in another herdr pane, unsent, then deleting
the review comments that went.
_Avoid_: send, post; "submit" never means GitHub here

**Review text**:
What a review is pasted or copied as: a part for each saved review comment, in order. Each part gives the comment's
place as a backticked absolute `path:Lfirst-Llast` (`path:Lline` for one line, the bare path for a whole file), then
`Feedback:` and its body. The configured header and footer, when set, go above and below the parts.
_Avoid_: payload, prompt

**Hand-off**:
A verb that acts on the whole review rather than on one review comment: submit, `review restore`, `review yank`,
`review abandon` and `comment list`.
_Avoid_: bare "review verbs", which also covers the single-comment ones

**Block**:
A review comment's whole text in a box drawn under its last line in its file, shown in
place of its first line while `:Changeset comment toggle` has blocks on.
_Avoid_: box, card, inline comment

**Parked block**:
The block a one-line move stopped the cursor on, as if it were a line of the file. Its
keys edit or delete its review comment.
_Avoid_: selected block, which **Selected** already means for the sidebar; focused block

**Origin**:
Where a review verb runs from: the sidebar, with its selected row, or a file's window. It names the repository the
verb acts on: the tree's from the sidebar, else the current buffer's.
_Avoid_: context, source, caller

**Comments section**:
The sidebar's first section, listing the repository's review comments, one comment row
each. It classifies no file.
_Avoid_: comment list, comments panel
