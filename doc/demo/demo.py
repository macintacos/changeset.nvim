#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["sh==2.4.0"]
# ///
"""Stage and play the README demo in a Rex session of its own, for you to record.

Clones the private changeset-sandbox's feat/session-store and opens two tabs on it: a
review in your own Neovim config, with this checkout's changeset ahead of the installed
one, and agent.py, a scripted stand-in for Claude Code. It opens the sidebar once out of
sight, so the language servers fill in its symbols, then waits while you start a screen
recording of the Rex window. Press Enter and Rex shows the session while the script types
the review, submits it to agent.py and watches its edits arrive. Stop the recording when
it says so, then press Enter again to close the session and delete the clone.

Turn the recording into the GIF, cutting what it caught before Rex showed the demo:

    ffmpeg -ss 2 -i recording.mov \
        -vf "fps=24,split[a][b];[a]palettegen[p];[b][p]paletteuse" doc/demo/demo.gif

With several Rex apps connected, set REX_CLIENT to the one you record.
"""

import json
import shutil
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Final, TypedDict

import sh

HERE: Final = Path(__file__).resolve().parent
REPO: Final = HERE.parent.parent
# A fixed path, since the statusline shows it.
SANDBOX: Final = "/tmp/changeset-sandbox"
SANDBOX_URL: Final = "https://github.com/macintacos/changeset-sandbox.git"
# Reads the agent's edits as they land, as Neovim regaining focus would.
CHECKTIME: Final = (
    "lua vim.uv.new_timer():start(1000, 1000,"
    ' vim.schedule_wrap(function() vim.cmd("silent! checktime") end))'
)
TYPING: Final = 0.07
# A block's creator owns it until an app shows it, and only its owner can resize it.
RESIZE: Final = """
local block = rex.args.block
assert(rex.session.own_block({ block_ids = { block } }))
assert(rex.block.call("com.superlogical.terminal", "resize",
  { block_id = block, columns = rex.args.columns, rows = rex.args.rows }))
"""
REX: Final = sh.Command("rex").bake(_tty_out=False)


class _Window(TypedDict):
    window_id: str
    block_ids: list[str]


class _Session(TypedDict):
    session_id: str
    initial_windows: list[_Window]


@dataclass(frozen=True, slots=True)
class Pane:
    """A terminal in the demo's session, which takes keys as if they were typed."""

    session: str
    block: str

    def write(self, text: str, every: float = TYPING) -> None:
        """Type `text`, a character every `every` seconds."""
        for char in text:
            self._paced(every, "send", "--", char)

    def press(self, key: str, times: int = 1, every: float = TYPING) -> None:
        """Press `key`, such as ctrl+g, `times` times, once every `every` seconds."""
        for _ in range(times):
            self._paced(every, "send-key", key)

    def resize(self, columns: int, rows: int) -> None:
        """Resize the terminal, which no app shows yet."""
        args = (f"block={self.block}", f"columns={columns}", f"rows={rows}")
        REX.do("-s", self.session, "-e", RESIZE, *args)

    def wait_for(self, text: str, timeout: float) -> None:
        """Wait until the screen shows `text`.

        Raises:
            TimeoutError: `text` did not show within `timeout` seconds.
        """
        until = time.monotonic() + timeout
        while text not in str(REX.capture("-s", self.session, "-b", self.block)):
            if time.monotonic() > until:
                raise TimeoutError(f"the screen never showed {text!r}")
            time.sleep(0.1)

    def _paced(self, every: float, command: str, *words: str) -> None:
        start = time.monotonic()
        REX(command, "-s", self.session, "-b", self.block, *words)
        time.sleep(max(0.0, every - (time.monotonic() - start)))


@dataclass(frozen=True, slots=True)
class Demo:
    """The demo's Rex session: the review's tab, then the agent's."""

    session: str
    review_window: str
    review: Pane
    agent: Pane


def _stage(state: str) -> Demo:
    """Open the session, Neovim's state in `state`, so the review starts empty."""
    nvim = ["env", f"XDG_STATE_HOME={state}", "nvim", "--cmd", f"set rtp^={REPO}"]
    nvim += ["-c", CHECKTIME, "src/session.ts"]
    tab = ["-c", SANDBOX, "--window", "review", "--json"]
    created: _Session = json.loads(str(REX.new("changeset-demo", *tab, "--", *nvim)))
    session = created["session_id"]
    review = created["initial_windows"][0]
    tab = ["new", "-s", session, "claude", "-c", SANDBOX, "--focus=false", "--json"]
    agent: _Window = json.loads(str(REX.window(*tab, "--", str(HERE / "agent.py"))))
    return Demo(
        session,
        review["window_id"],
        Pane(session, review["block_ids"][0]),
        Pane(session, agent["block_ids"][0]),
    )


def _warm_up(review: Pane) -> None:
    """Open the sidebar once out of sight, so the language servers fill in its symbols."""
    # Room for the sidebar to list the symbol awaited; the app resizes it later.
    review.resize(160, 45)
    review.wait_for("session.ts", 30)
    review.press("ctrl+g")
    review.write("g")
    review.wait_for("parseToken", 60)
    time.sleep(1)
    review.write("q")
    time.sleep(1)


def _open_comment(review: Pane) -> None:
    """Open the comment window, stopping a take whose keys would land elsewhere."""
    review.press("ctrl+g")
    review.write("cc")
    review.wait_for("review-comment://", 2)
    time.sleep(0.4)


def _quit(review: Pane) -> None:
    """Quit Neovim and wait for it, so it writes nothing more as the clean-up deletes."""
    review.press("escape")
    review.write(":qa!", 0)
    review.press("enter")
    # 3: the pane closed with Neovim before the wait found it.
    REX.wait("-s", review.session, "--for", "10s", review.block, _ok_code=[0, 3])


def _view_files(review: Pane) -> None:
    """Open the sidebar and mark files viewed, each mark moving on to the next file."""
    time.sleep(0.8)
    review.press("ctrl+g")
    review.write("g")
    time.sleep(1.4)
    review.write("H")
    time.sleep(1.2)
    review.write("gg")
    time.sleep(0.2)
    review.write("j")
    time.sleep(0.9)
    review.write("x")
    time.sleep(1.7)
    review.write("x")
    time.sleep(0.8)
    review.write("x")
    time.sleep(0.5)
    review.write("l")
    time.sleep(0.45)
    review.write("jjj", 0.065)
    time.sleep(1.3)


def _comment_on_cache_size(review: Pane) -> None:
    _open_comment(review)
    review.write("config", 0.06)
    review.write(".toml", 0.095)
    time.sleep(0.14)
    review.write(" adds ", 0.05)
    time.sleep(0.3)
    review.write("`", 0.11)
    review.write("session_cahce", 0.055)
    time.sleep(0.38)
    review.press("backspace", 3, 0.11)
    review.write("che_size", 0.075)
    review.write("`", 0.13)
    time.sleep(0.2)
    review.write(", but this", 0.045)
    time.sleep(0.16)
    review.write(" still ", 0.06)
    time.sleep(0.24)
    review.write("hard-codes ", 0.07)
    review.write("128", 0.12)
    review.write(".", 0.04)
    time.sleep(0.75)
    review.write(" Pass it", 0.055)
    time.sleep(0.12)
    review.write(" in?", 0.065)
    time.sleep(0.45)
    review.press("ctrl+s")
    time.sleep(0.9)


def _comment_on_lifetime(review: Pane) -> None:
    review.write("jjj", 0.06)
    time.sleep(1.1)
    review.press("enter")
    time.sleep(0.8)
    review.write("j")
    time.sleep(0.25)
    review.write("V")
    time.sleep(0.15)
    review.write("jj", 0.09)
    time.sleep(0.35)
    _open_comment(review)
    review.write("This never ", 0.055)
    time.sleep(0.6)
    review.press("backspace", 6, 0.035)
    time.sleep(0.25)
    review.write("can live ", 0.06)
    time.sleep(0.45)
    review.press("backspace", 14, 0.035)
    time.sleep(0.3)
    review.write("Nothing caps", 0.05)
    time.sleep(0.18)
    review.write(" the lifetime", 0.07)
    review.write(": ", 0.1)
    time.sleep(0.42)
    review.write("a client", 0.055)
    time.sleep(0.13)
    review.write(" refreshing evry", 0.065)
    time.sleep(0.2)
    review.press("backspace", 2, 0.09)
    review.write("ery few minutes ", 0.06)
    time.sleep(0.26)
    review.write("keeps a session", 0.05)
    time.sleep(0.15)
    review.write(" forever.", 0.075)
    time.sleep(0.5)
    review.press("ctrl+s")
    time.sleep(1)


def _walk_changes(review: Pane) -> None:
    """Step through the rest of the file, change by change."""
    for wait in (0.75, 0.75, 1.7):
        review.press("ctrl+g")
        review.write("nn")
        time.sleep(wait)


def _comment_on_tests(review: Pane) -> None:
    review.press("ctrl+g")
    review.write("g")
    time.sleep(0.6)
    review.write("]]")
    time.sleep(0.6)
    review.write("jjj", 0.08)
    time.sleep(0.35)
    review.write("l")
    time.sleep(1.4)
    _open_comment(review)
    review.write("Add a ", 0.055)
    time.sleep(0.15)
    review.write("revoke case", 0.07)
    review.write(": ", 0.09)
    time.sleep(0.38)
    review.write("`get`", 0.12)
    time.sleep(0.14)
    review.write(" reads the cache", 0.05)
    review.write(" first, ", 0.065)
    time.sleep(0.55)
    review.write("so check a revoekd", 0.055)
    time.sleep(0.3)
    review.press("backspace", 3, 0.095)
    review.write("ked session", 0.07)
    time.sleep(0.14)
    review.write(" stays gone.", 0.06)
    time.sleep(0.45)
    review.press("ctrl+s")
    time.sleep(0.9)


def _filter(review: Pane) -> None:
    """Filter the tree, then clear it: the prompt opens holding the current filter."""
    review.write("f")
    time.sleep(0.3)
    review.write("toml", 0.095)
    time.sleep(0.5)
    review.press("enter")
    time.sleep(1.6)
    review.write("f")
    time.sleep(0.25)
    review.press("ctrl+u")
    time.sleep(0.15)
    review.press("enter")
    time.sleep(0.8)


def _submit(demo: Demo) -> None:
    """Submit, which pastes the review into the agent's prompt and focuses its tab."""
    demo.review.press("ctrl+g")
    demo.review.write("s")
    time.sleep(2.2)
    demo.agent.press("enter")
    time.sleep(6.5)


def _watch_edits(demo: Demo) -> None:
    """Go back to the review, where the agent's edits arrive in the tree and preview."""
    REX("focus", "-s", demo.session, demo.review_window)
    time.sleep(0.9)
    demo.review.write("gg")
    time.sleep(0.2)
    demo.review.write("jjjj")
    time.sleep(10)


def _play(demo: Demo) -> None:
    _view_files(demo.review)
    _comment_on_cache_size(demo.review)
    _comment_on_lifetime(demo.review)
    _walk_changes(demo.review)
    _comment_on_tests(demo.review)
    _filter(demo.review)
    _submit(demo)
    _watch_edits(demo)


def main() -> None:
    """Stage the demo, play it while you record, then clean up."""
    sh.git.clone("--quiet", "--branch", "feat/session-store", SANDBOX_URL, SANDBOX)
    try:
        # Neovim may still be writing its state when a failed take kills it.
        with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as state:
            demo = _stage(state)
            try:
                _warm_up(demo.review)
                input(
                    "Start recording the Rex window, then press Enter to play the demo."
                )
                REX.do("session.select", f"session_id={demo.session}")
                _play(demo)
                input("Stop the recording, then press Enter to close the demo.")
                _quit(demo.review)
            finally:
                REX.kill(demo.session)
    finally:
        shutil.rmtree(SANDBOX)


if __name__ == "__main__":
    main()
