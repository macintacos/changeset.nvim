# Rex calls

`lua/changeset/agent.lua` hands a review to an AI agent running in another pane of the same
Rex session. It pastes the text into the agent's prompt unsent and focuses that pane, so the
user adds context and presses Enter. These are the calls it makes, the JSON it reads, and
what each one can surprise you with.

## Calls

Each call runs `rex` from PATH through `Process.run` with a 5-second timeout, scoped with
`-s $REX_SESSION`. A spawn that fails, the binary gone since the check or an argv over the
OS limit, counts as a refused call.

| Command                                     | Reads                               |
| ------------------------------------------- | ----------------------------------- |
| `rex do -s <session> -e <LIST>`             | `{"panes":[…]}`                     |
| `rex api call -s <session> block.event -`   | nothing; the paste event on stdin   |
| `rex focus -s <session> <block_id>`         | nothing                             |

`LIST` is a Lua script that runs inside `rex do`, in Rex's own Lua 5.1, not Neovim's. For
each terminal block of the session it returns the block's `block_id` and `label`, the
`records` of its `program_status` method and the `foreground` of its `process` method. The
specs fake `rex`, so they never run the script: check a change to it against a real Rex
server, from a Rex pane, before committing.

## Which panes are agents

A program reports its state to Rex with OSC 7501, the program status escape sequence, and
Claude Code does. `program_status` lists the reports as records, the program's own, the
root record, first and without an `id`. A pane holds an agent when its root record names
an `effective_app` and the record's `owner`, the pane's foreground process when the report
arrived, is still its foreground process, by both `pid` and `name`, since the system reuses
process IDs. Rex keeps an `idle` or `done` record after its program exits, and without the
owner check a shell left at its prompt would list as the agent that ran there. The pane
changeset runs in, `$REX_BLOCK`, never lists.

Without a non-empty `$REX_SESSION`, Neovim is not in a Rex pane, and changeset makes no
call at all; with it but no `rex` on PATH, changeset says so and makes none either.

An agent's `state` is `idle`, `working`, `done`, `blocked` or `error`; `idle` and `done`
both mean it is ready for input. A row names it by `effective_app`, such as `claude-code`,
and ends with the block's label, which Claude Code sets to its conversation's title. Its
directory is the foreground process's `cwd`, and its branch is read off the git files of the
repository holding that directory, without running git.

## Ranking the picker

With several agents the picker lists, in order: the agent this repository's branch last
sent to in this Neovim, while its pane's directory is still the one it had then, since a
pane outlives its agent; then agents working in this repository; then the rest. An agent
works in it when its directory is inside one of the repository's worktrees, which
`git worktree list --porcelain` run in its root lists, its own included. git names a
worktree by its real path, so the agent's directory is resolved first. The branch is shown
but never ranks, since branch names repeat across repositories. Within each group ready
agents come first, then working, then any other state, then blocked; ties keep Rex's
order. Focus starts on the first agent that can be picked in the first two groups, else on
none. That git call runs only when there is a pick to make; a failed one ranks by the last
agent and the states alone.

## Null fields

Rex writes some absent fields as `null`, a record's `owner` and a process's `foreground`
among them, and leaves others out; the listing writes an empty list as `{}`. Decode with
`luanil`, or a `null` becomes `vim.NIL`, which is truthy.

## The ready check

Rex has no atomic paste-if-ready, and a pick can be minutes old, so changeset lists the
panes again right before writing. A pane that is gone, or whose agent no longer runs in its
foreground, means the agent closed. A `blocked` state means the agent is at a prompt, such
as a permission prompt, which silently drops a paste, so changeset refuses until the user
answers it. The picker already won't pick a blocked agent, but the check still runs, since
the list it drew can be minutes old. Every other state takes the paste: one during a
`working` turn waits in the input.

## The paste

The text goes in one `block.event` call, a `paste` event whose payload is
`{"text": "…"}`, sent as JSON on stdin so its size never meets the argv limit. Rex wraps it
in `ESC[200~` and `ESC[201~`, the bracketed-paste markers, when the agent turned bracketed
paste on, as Claude Code does, and disarms any `ESC[201~` inside it. Without the markers
each newline would reach the agent as Enter and submit a fragment.

A paste sends no Enter, and changeset never adds one: the user submits.

## Errors

A failed call exits non-zero and writes `Error: …` to stderr. Exit status 3 means a target
was not found: from the paste, the agent's pane closed. Any other status reads as Rex
refusing the paste. Never show rex's raw output or a block id to the user.

## Focus

Focus runs after a delivered paste and is best effort: a failed focus still reports the
paste as done, since the text is already in the agent's input.
