#!/usr/bin/env bash
# Stage the review that doc/demo/demo.tape records.
#
# Clones the sandbox's feat/session-store and opens it in your own Neovim config, with this
# checkout's changeset ahead of the installed one on 'runtimepath'.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
# A fixed path, since the statusline shows it.
sandbox=/tmp/changeset-sandbox
git clone --quiet --branch feat/session-store https://github.com/macintacos/changeset-sandbox.git "$sandbox"
# A fresh state dir starts the review with no comments or viewed marks, and keeps the
# recording's out of yours.
state="$(mktemp -d)"
trap 'rm -rf "$sandbox" "$state"' EXIT

cd "$sandbox"
# Without herdr's variables, submit can't reach your agents.
unset "${!HERDR_@}"
# smear-cursor's animation blanks whole frames in vhs's capture.
XDG_STATE_HOME="$state" nvim --cmd "set rtp^=$repo" \
	-c 'lua pcall(function() require("smear_cursor").enabled = false end)' \
	src/session.ts
