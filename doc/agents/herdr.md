# herdr calls

`lua/changeset/herdr.lua` hands a review to an AI agent running in another pane of herdr,
the terminal multiplexer. It pastes the text into the agent's prompt unsent and focuses
that pane, so the user adds context and presses Enter. These are the calls it makes, the
JSON it reads, and what each one can surprise you with.

## Calls

Each call runs `herdr` from PATH through `vim.system` with a 5-second timeout. A spawn that
fails, the binary gone since the check or an argv over the OS limit, counts as a refused
call.

| Command                                | Reads                                                     |
| -------------------------------------- | --------------------------------------------------------- |
| `herdr agent list`                     | `{"result":{"agents":[…]}}`                               |
| `herdr pane send-text <pane_id> <txt>` | nothing on success                                        |
| `herdr agent focus <pane_id>`          | nothing                                                   |

An agent entry carries `agent`, `agent_status`, `pane_id`, `tab_id`, `workspace_id`,
`title`, `cwd`, `foreground_cwd`, `tokens` and `focused`. `agent_status` is `idle`,
`working`, `blocked`, `done` or `unknown`; `idle` and `done` both mean the agent is ready
for input. herdr leaves `name`, `display_agent` and `state_labels`, a `{status = label}`
map, out of an entry until something sets them, so changeset reads each as optional.

`cwd` is the pane's directory and `foreground_cwd` the directory of the program in its
foreground, the agent itself. They differ when the pane started in one directory and the
agent runs in another, so changeset reads `foreground_cwd` first. `tokens.branch` is the
branch checked out there.

## Ranking the picker

With several agents the picker lists, in order: the agent this repository's branch last
sent to in this Neovim, while its pane's directory is still the one it had then, since a
herdr pane outlives its agent; then agents working in this repository; then the rest. An
agent works in it when its directory is inside one of the repository's worktrees, which
one `git worktree list --porcelain` run in its root lists, its own included. git names a
worktree by its real path, so the agent's directory is resolved first. `tokens.branch` is
shown but never ranks, since branch names repeat across repositories. Within each group
ready agents come first, then working, then any other status, then blocked; ties keep
herdr's order. Focus starts on the first agent that can be picked in the first two groups,
else on none. That git call runs only when there is a pick to make; a failed one ranks by
the last agent and the statuses alone.

## Workspace scoping

`agent list` lists every agent in every workspace. changeset keeps only entries with a
non-empty `agent`, a `workspace_id` equal to `$HERDR_WORKSPACE_ID` and a `pane_id` other
than `$HERDR_PANE_ID`, its own pane. Without a non-empty `$HERDR_WORKSPACE_ID`, Neovim is not in a
herdr pane, and changeset makes no call at all; with it but no `herdr` on PATH, changeset
says so and makes none either.

## Null fields

herdr writes an absent field as `null`, leaves it out, or writes `""`. Treat all three as
absent. Decode with `luanil`, or `vim.json.decode` turns `null` into `vim.NIL`, which is
truthy.

## The ready check

herdr has no atomic paste-if-ready, and a pick can be minutes old, so changeset reads
`agent list` again right before writing. A pane that is gone means the agent closed. An
`agent_status` of `blocked` means the agent is at a permission prompt, which silently
drops a paste, so changeset refuses until the user answers it. The picker already won't
pick a blocked agent, but the check still runs, since the list it drew can be minutes
old. Every other status takes the paste: one during a `working` turn waits in the input.

## The paste

The text goes in one `send-text` call wrapped in `ESC[200~` and `ESC[201~`, the
bracketed-paste markers. Without them each newline reaches the agent as Enter and submits
a fragment. Every `ESC[201~` inside the text is removed first, repeating until none is
left, since removing one can join the pieces of another.

`send-text` sends no Enter, and changeset never adds one: the user submits.

## Errors

A failed call exits non-zero and writes an envelope to stderr:

```json
{ "error": { "code": "pane_not_found", "message": "pane w8:p2 not found" } }
```

`pane_not_found` from `send-text` reads as the agent having closed. Any other code reads as
herdr refusing the paste. Never show herdr's raw JSON or a pane id to the user.

## Focus

Focus runs after a delivered paste and is best effort: a failed focus still reports the
paste as done, since the text is already in the agent's input.
