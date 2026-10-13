#!/usr/bin/env bash
# What the demo herdr session's panes run in place of a shell. The first opens a tab for
# agent.py, then reviews in your own Neovim config, with this checkout's changeset ahead of
# the installed one.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
# Neovim's 'shell' and agent.py's subprocesses take it.
export SHELL="$DEMO_SHELL"

if [[ ${DEMO_ROLE:-} == agent ]]; then
	exec "$here/agent.py"
fi
herdr tab create --cwd "$PWD" --label claude --no-focus --env DEMO_ROLE=agent >/dev/null
herdr tab rename "$HERDR_TAB_ID" review >/dev/null

# smear-cursor's animation blanks whole frames in vhs's capture. The timer reads the
# agent's edits as they land, as Neovim regaining focus would.
exec nvim --cmd "set rtp^=$repo" \
	-c 'lua pcall(function() require("smear_cursor").enabled = false end)' \
	-c 'lua vim.uv.new_timer():start(1000, 1000, vim.schedule_wrap(function() vim.cmd("silent! checktime") end))' \
	src/session.ts
