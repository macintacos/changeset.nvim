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
