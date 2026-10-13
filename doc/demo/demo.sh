#!/usr/bin/env bash
# Stage the review that doc/demo/demo.tape records.
#
# Clones the sandbox's feat/session-store and opens a herdr session of its own on it, whose
# panes run panes.sh in place of a shell. Quitting herdr deletes the session and the clone.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# A fixed path, since the statusline shows it.
sandbox=/tmp/changeset-sandbox
session=changeset-demo
git clone --quiet --branch feat/session-store https://github.com/macintacos/changeset-sandbox.git "$sandbox"
# A fresh state dir starts the review with no comments or viewed marks, and keeps the
# recording's out of yours.
state="$(mktemp -d)"
cleanup() {
	herdr session stop "$session" >/dev/null 2>&1 || true
	herdr session delete "$session" >/dev/null 2>&1 || true
	rm -rf "$sandbox" "$state"
}
trap cleanup EXIT

cd "$sandbox"
# Run from inside herdr, its variables would point the session's panes at yours.
unset "${!HERDR_@}"
export DEMO_SHELL="$SHELL"
SHELL="$here/panes.sh" XDG_STATE_HOME="$state" herdr --session "$session"
