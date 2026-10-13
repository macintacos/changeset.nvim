#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""A scripted stand-in for Claude Code that doc/demo/demo.tape submits a review to.

It tells herdr it is a claude agent, shows what is pasted as its prompt, and on Enter
plays a turn that makes the review's changes to the sandbox, showing each as a diff.
"""

import codecs
import difflib
import os
import select
import shutil
import subprocess
import sys
import termios
import textwrap
import time
import tty
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Final, Literal

PINK: Final = "255;128;191"
GREY: Final = "112;140;169"
RULE: Final = "54;64;73"
GREEN: Final = "138;255;128"
ORANGE: Final = "255;202;128"
ADDED_BG: Final = "28;58;30"
REMOVED_BG: Final = "68;30;34"
SPINNER: Final = "·✢✳✶✻✽"
PASTE_START: Final = "\x1b[200~"
PASTE_END: Final = "\x1b[201~"
HERDR_SOURCE: Final = ["--source", "changeset-demo", "--agent", "claude"]

type AgentState = Literal["idle", "working"]


def _fg(rgb: str, text: str) -> str:
    return f"\x1b[38;2;{rgb}m{text}\x1b[0m"


def _bg(rgb: str, text: str) -> str:
    return f"\x1b[48;2;{rgb}m{text}\x1b[0m"


def _tool(call: str) -> str:
    return _fg(GREEN, "⏺ ") + f"\x1b[1m{call}\x1b[0m"


def _result(text: str) -> str:
    return _fg(GREY, "  ⎿  ") + text


def _count(number: int, noun: str) -> str:
    return f"{number} {noun}{'s' * (number != 1)}"


def _wrap(text: str, width: int) -> list[str]:
    """`text` wrapped to `width`, blank lines kept: the screen places lines by row."""
    return [
        part for line in text.split("\n") for part in textwrap.wrap(line, width) or [""]
    ]


def _welcome() -> list[str]:
    title, cwd = "Welcome to Claude Code!", f"  cwd: {os.getcwd()}"
    width = max(len(title) + 2, len(cwd))
    side = _fg(PINK, "│")
    return [
        _fg(PINK, "╭" + "─" * (width + 2) + "╮"),
        f"{side} " + _fg(PINK, "✻") + f" \x1b[1m{title.ljust(width - 2)}\x1b[0m {side}",
        f"{side} {' ' * width} {side}",
        f"{side} " + _fg(GREY, cwd.ljust(width)) + f" {side}",
        _fg(PINK, "╰" + "─" * (width + 2) + "╯"),
        "",
    ]


def _herdr(*args: str) -> None:
    """Run a herdr pane command on this pane; changeset submits to the agent it names."""
    pane = os.environ.get("HERDR_PANE_ID")
    if pane:
        subprocess.run(
            ["herdr", "pane", *args, *HERDR_SOURCE, pane],
            capture_output=True,
            check=False,
        )


def _report(state: AgentState) -> None:
    _herdr("report-agent", "--state", state)


def _diff(before: str, after: str) -> list[str]:
    """`before` to `after` as Claude Code shows an edit: a count, then numbered lines."""
    old, new = before.splitlines(), after.splitlines()
    added = removed = 0
    body: list[str] = []
    groups = difflib.SequenceMatcher(None, old, new).get_grouped_opcodes(1)
    for n, group in enumerate(groups):
        if n:
            body.append(_fg(GREY, f"{'...':>6}"))
        for tag, i1, i2, j1, j2 in group:
            if tag == "equal":
                body += [
                    _fg(GREY, f"{j + 1:>6}") + f"    {new[j]}" for j in range(j1, j2)
                ]
                continue
            body += [_bg(REMOVED_BG, f"{i + 1:>6} -  {old[i]}") for i in range(i1, i2)]
            body += [_bg(ADDED_BG, f"{j + 1:>6} +  {new[j]}") for j in range(j1, j2)]
            removed, added = removed + i2 - i1, added + j2 - j1
    return [f"with {_count(added, 'addition')} and {_count(removed, 'removal')}", *body]


@dataclass(frozen=True, slots=True)
class Edit:
    """One replacement the turn makes in a sandbox file."""

    path: str
    old: str
    new: str


def _update(*edits: Edit) -> list[str]:
    """Make `edits`, all to one file, and show them as one Update."""
    path = edits[0].path
    file = Path(path)
    before = after = file.read_text()
    for edit in edits:
        if edit.old not in after:
            raise ValueError(f"{path} no longer holds the text an edit replaces")
        after = after.replace(edit.old, edit.new, 1)
    file.write_text(after)
    summary, *body = _diff(before, after)
    return [_tool(f"Update({path})"), _result(f"Updated {path} {summary}"), *body]


CACHE_SIZE: Final = Edit(
    "src/session.ts",
    """  private readonly recent = new LruCache<string, Session>(128);

  constructor(private readonly ttlMs: number) {}
""",
    """  private readonly recent: LruCache<string, Session>;

  constructor(
    private readonly ttlMs: number,
    cacheSize = 128,
    private readonly maxAgeMs = 604_800_000,
  ) {
    this.recent = new LruCache(cacheSize);
  }
""",
)
MAX_AGE_CONFIG: Final = Edit(
    "config.toml",
    "session_cache_size = 128\n",
    "session_cache_size = 128\nsession_max_age_ms = 604800000\n",
)
CREATED_AT_FIELD: Final = Edit(
    "src/session.ts",
    "  expiresAt: number;\n",
    "  createdAt: number;\n  expiresAt: number;\n",
)
CREATED_AT: Final = Edit(
    "src/session.ts", "user, expiresAt: now", "user, createdAt: now, expiresAt: now"
)
REFRESH_CAP: Final = Edit(
    "src/session.ts",
    """  /** Extends a session that is still alive by a full ttl from `now`. */
  refresh(id: string, now: number): Session | undefined {
    const session = this.get(id, now);
    if (!session) return undefined;
    session.expiresAt = now + this.ttlMs;""",
    """  /** Extends a live session by a full ttl from `now`, never past its max age. */
  refresh(id: string, now: number): Session | undefined {
    const session = this.get(id, now);
    if (!session) return undefined;
    const cap = session.createdAt + this.maxAgeMs;
    session.expiresAt = Math.min(now + this.ttlMs, cap);""",
)
TESTS: Final = Edit(
    "tests/session.test.ts",
    """    expect(store.refresh(s.id, 1000)).toBeUndefined();
  });
""",
    """    expect(store.refresh(s.id, 1000)).toBeUndefined();
  });

  it("stops refreshing at the max age", () => {
    const store = new SessionStore(1000, 128, 1500);
    const s = store.create("ada", 0);
    store.refresh(s.id, 900);
    expect(store.get(s.id, 1500)).toBeUndefined();
  });

  it("forgets a revoked session, cached or not", () => {
    const store = new SessionStore(1000);
    const s = store.create("ada", 0);
    store.get(s.id, 10);
    store.revoke(s.id);
    expect(store.get(s.id, 20)).toBeUndefined();
  });
""",
)

PASSED: Final = _fg(GREEN, "✓")

type Step = tuple[float, Callable[[], list[str]]]

# The waits pace the edits the recording watches land in Neovim. src/session.ts, the
# buffer Neovim has loaded, goes last: reloading it rebuilds the tree, which then reads
# every earlier edit.
TURN: Final[tuple[Step, ...]] = (
    (
        1.4,
        lambda: [
            _tool("Skill(superpowers:receiving-code-review)"),
            _result("Successfully loaded skill"),
        ],
    ),
    (1.6, lambda: ["⏺ All three hold up. I'll make the changes, then run the suite."]),
    (0.9, lambda: [_tool("Read(src/session.ts)"), _result("Read 72 lines")]),
    (1.6, lambda: _update(CACHE_SIZE)),
    (2.2, lambda: _update(MAX_AGE_CONFIG)),
    (2.0, lambda: _update(CREATED_AT_FIELD, CREATED_AT)),
    (2.6, lambda: _update(TESTS)),
    (2.2, lambda: _update(REFRESH_CAP)),
    (
        1.8,
        lambda: [
            _tool("Bash(npm test)"),
            _result(f"{PASSED} tests/session.test.ts (6 tests)"),
            f"     {PASSED} tests/cache.test.ts (1 test)",
            f"     {PASSED} src/session.ts (1 test)",
            "",
            "     Tests  " + _fg(GREEN, "8 passed") + " (8)",
        ],
    ),
    (
        1.0,
        lambda: [
            "⏺ Done. All three comments are addressed:",
            "  - SessionStore takes the cache size, defaulting to config.toml's 128",
            "  - refresh() stops at a max age, session_max_age_ms in config.toml",
            "  - New tests cover the max age and revoking a cached session",
        ],
    ),
)


@dataclass(slots=True)
class Screen:
    """A welcome, the transcript, a spinner while the turn plays, then the prompt."""

    transcript: list[str] = field(default_factory=list)
    prompt: str = ""
    working_since: float | None = None
    pasting: bool = False
    # The start of an escape sequence the last read cut off, finished by the next.
    held: str = ""

    def draw(self) -> None:
        """Repaint the whole screen in one write, line by line over the last frame."""
        cols, rows = shutil.get_terminal_size()
        rule = _fg(RULE, "─" * cols)
        head = _welcome()
        prompt = _wrap(self.prompt, cols - 2)
        foot = [
            rule,
            *[
                (_fg(GREY, "❯ ") if i == 0 else "  ") + line
                for i, line in enumerate(prompt)
            ],
            rule,
            _fg(ORANGE, "  ⏵⏵ accept edits on") + _fg(GREY, " (shift+tab to cycle)"),
        ]
        if self.working_since is not None:
            elapsed = time.monotonic() - self.working_since
            spin = SPINNER[int(elapsed * 8) % len(SPINNER)]
            status = _fg(GREY, f" ({int(elapsed)}s · esc to interrupt)")
            foot = ["", _fg(PINK, f"{spin} Working…") + status, "", *foot]
        room = max(rows - len(head) - len(foot), 0)
        body = self.transcript[-room:] if room else []
        lines = head + body + [""] * (room - len(body)) + foot
        frame = "".join(
            f"\x1b[{i + 1};1H{line}\x1b[K" for i, line in enumerate(lines[:rows])
        )
        # The last prompt line sits above the closing rule and the mode line.
        cursor = f"\x1b[{min(len(lines), rows) - 2};{len(prompt[-1]) + 3}H"
        sys.stdout.write("\x1b[?25l" + frame + cursor + "\x1b[?25h")
        sys.stdout.flush()


def _read_keys(decoder: codecs.IncrementalDecoder, timeout: float) -> str:
    ready, _, _ = select.select([sys.stdin], [], [], timeout)
    if not ready:
        return ""
    return decoder.decode(os.read(sys.stdin.fileno(), 65536))


def _take_input(screen: Screen, keys: str) -> bool:
    """Apply `keys` to the prompt.

    Returns:
        Whether Enter was pressed.
    """
    keys = screen.held + keys
    start = keys.rfind("\x1b")
    if start != -1 and len(keys) - start < len(PASTE_START):
        keys, screen.held = keys[:start], keys[start:]
    else:
        screen.held = ""
    while keys:
        if screen.pasting:
            text, found, keys = keys.partition(PASTE_END)
            screen.prompt += text.replace("\r\n", "\n").replace("\r", "\n")
            screen.pasting = not found
        elif keys.startswith(PASTE_START):
            keys, screen.pasting = keys[len(PASTE_START) :], True
        else:
            key, keys = keys[0], keys[1:]
            if key == "\r":
                return True
            if key in ("\x03", "\x04"):
                raise KeyboardInterrupt
            if key == "\x7f":
                screen.prompt = screen.prompt[:-1]
            elif key.isprintable():
                screen.prompt += key
    return False


def _play(screen: Screen) -> None:
    sent = _wrap(screen.prompt.strip(), shutil.get_terminal_size().columns - 4)
    screen.transcript += [_fg(GREY, "> " + line) for line in sent] + [""]
    screen.prompt = ""
    screen.working_since = time.monotonic()
    _report("working")
    for wait, step in TURN:
        until = time.monotonic() + wait
        while time.monotonic() < until:
            screen.draw()
            time.sleep(0.1)
        screen.transcript += [*step(), ""]
    screen.working_since = None
    screen.draw()
    _report("idle")


def main() -> None:
    """Run until Ctrl-C, playing the turn on the first prompt sent."""
    screen = Screen()
    decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
    attrs = termios.tcgetattr(sys.stdin)
    sys.stdout.write("\x1b[?1049h\x1b[?2004h\x1b[2J")
    try:
        tty.setraw(sys.stdin)
        _report("idle")
        played = False
        while True:
            screen.draw()
            entered = _take_input(screen, _read_keys(decoder, 0.25))
            if entered and screen.prompt.strip() and not played:
                _play(screen)
                played = True
    except KeyboardInterrupt:
        pass
    finally:
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, attrs)
        sys.stdout.write("\x1b[?2004l\x1b[?1049l")
        sys.stdout.flush()
        _herdr("release-agent")


if __name__ == "__main__":
    main()
