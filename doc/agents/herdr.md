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
| `herdr tab list --workspace <ws>`      | `{"result":{"tabs":[{"tab_id","label",…}]}}`              |
| `herdr pane send-text <pane_id> <txt>` | nothing on success                                        |
| `herdr agent focus <pane_id>`          | nothing                                                   |

An agent entry carries `agent`, `agent_status`, `pane_id`, `tab_id`, `workspace_id`,
`title`, `cwd` and `focused`. herdr leaves `name`, `display_agent` and `state_labels`, a
`{status = label}` map, out of an entry until something sets them, so changeset reads each
as optional.

`tab list` runs only when the user must pick between several agents, and only for the tab
labels in the picker rows. A failed one leaves the rows without a tab.

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

herdr has no atomic send-if-ready, and a pick can be minutes old, so changeset reads
`agent list` again right before writing. A pane that is gone means the agent closed. An
`agent_status` of `blocked` means the agent is at a permission prompt, which silently
drops a paste, so changeset refuses until the user answers it. Every other status sends:
a paste during a `working` turn waits in the input.

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
herdr refusing the send. Never show herdr's raw JSON or a pane id to the user.

## Focus

Focus runs after a delivered paste and is best effort: a failed focus still reports the
send as done, since the text is already in the agent's input.
