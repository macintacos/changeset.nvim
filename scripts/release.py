#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["cyclopts==5.2.0", "pydantic==2.14.1", "semver==3.1.0"]
# ///
"""Compute and cut a changeset.nvim release of origin/main, printing one JSON object."""

import shutil
import subprocess
import sys
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import Annotated, Final, Literal, get_args

import semver
from cyclopts import App, CycloptsError
from pydantic import (
    AfterValidator,
    BaseModel,
    ConfigDict,
    Field,
    FilePath,
    TypeAdapter,
    ValidationError,
)
from pydantic.alias_generators import to_camel

Bump = Literal["patch", "minor", "major"]

FIRST_VERSION: Final = semver.Version(0, 1, 0)


def latest_tag(tags: Iterable[str]) -> str | None:
    """The highest `v<semver>` tag by precedence, or None when there is none.

    Args:
        tags: Tag names, without the `refs/tags/` prefix.

    Returns:
        The latest release tag, or None.
    """
    versions = {
        tag: semver.Version.parse(tag[1:])
        for tag in tags
        if tag.startswith("v") and semver.Version.is_valid(tag[1:])
    }
    return max(versions, key=versions.__getitem__, default=None)


def next_version(previous_tag: str | None, bump: Bump) -> semver.Version:
    """The version `bump` gives after `previous_tag`; the first release is 0.1.0.

    Args:
        previous_tag: The latest release tag, or None before the first release.
        bump: Which component to bump.

    Returns:
        The next version.
    """
    if previous_tag is None:
        return FIRST_VERSION
    return semver.Version.parse(previous_tag[1:]).next_version(bump)


class _Model(BaseModel):
    model_config = ConfigDict(
        alias_generator=to_camel, serialize_by_alias=True, validate_by_name=True
    )


class Commit(_Model):
    """A commit the release would ship."""

    sha: str
    subject: str


class _Run(_Model):
    status: str
    conclusion: str | None
    url: str


def _non_empty(path: Path) -> Path:
    if path.stat().st_size == 0:
        raise ValueError("the notes file is empty")
    return path.resolve()


class _ReleaseInput(_Model):
    version: Annotated[str, AfterValidator(lambda v: str(semver.Version.parse(v)))]
    sha: Annotated[str, Field(pattern=r"^[0-9a-f]{40}$")]
    notes_file: Annotated[FilePath, AfterValidator(_non_empty)]


@dataclass(frozen=True, slots=True)
class Snapshot:
    """What origin says the next release would contain."""

    sha: str
    previous_tag: str | None
    commits: list[Commit]


class Refusal(Exception):
    """A gate that stops the release, reported as `{"ok": false, ...}`."""

    def __init__(self, error_code: str, message: str):
        """Name the refusal.

        Args:
            error_code: The envelope's `errorCode`.
            message: What went wrong.
        """
        super().__init__(message)
        self.error_code = error_code


def _run(*args: str) -> str:
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != 0:
        raise Refusal("COMMAND_FAILED", f"{' '.join(args)}: {result.stderr.strip()}")
    return result.stdout


def _require_gh() -> None:
    if shutil.which("gh") is None:
        raise Refusal("NO_GH", "gh is not on PATH")
    # Plain status: with --json it always exits 0.
    auth = subprocess.run(["gh", "auth", "status"], capture_output=True, text=True)
    if auth.returncode != 0:
        raise Refusal("GH_UNAUTHENTICATED", auth.stderr.strip() or "gh is not logged in")


def _commit(line: str) -> Commit:
    sha, subject = line.split("\x1f", 1)
    return Commit(sha=sha, subject=subject)


def snapshot() -> Snapshot:
    """Read origin/main, the latest tag on origin, and the commits since it.

    Returns:
        The snapshot.
    """
    _require_gh()
    # So `git log` can resolve the previous tag.
    _run("git", "fetch", "--tags", "--force", "origin")
    sha = _run("git", "rev-parse", "origin/main").strip()
    refs = _run("git", "ls-remote", "--tags", "--refs", "origin", "refs/tags/v*")
    previous = latest_tag(
        line.split("\t")[1].removeprefix("refs/tags/") for line in refs.splitlines()
    )
    span = f"{previous}..{sha}" if previous else sha
    log = _run("git", "log", "--format=%H%x1f%s", span)
    return Snapshot(sha, previous, [_commit(line) for line in log.splitlines()])


def require_releasable(snap: Snapshot, tag: str) -> None:
    """Refuse unless there are commits, `tag` is free, and CI passed on the SHA.

    Args:
        snap: The snapshot to release.
        tag: The tag the release would create.

    Raises:
        Refusal: When a gate fails.
    """
    if not snap.commits:
        raise Refusal("NO_COMMITS", f"no commits follow {snap.previous_tag}")
    if _run("git", "ls-remote", "--tags", "origin", f"refs/tags/{tag}").strip():
        raise Refusal("TAG_EXISTS", f"{tag} already exists on origin")
    runs_json = _run(
        "gh", "run", "list", "--workflow", "CI", "--branch", "main", "--event", "push",
        "--commit", snap.sha, "--json", "status,conclusion,url", "--limit", "1",
    )  # fmt: skip
    runs = TypeAdapter(list[_Run]).validate_json(runs_json)
    if not runs:
        raise Refusal("CI_NO_RUN", f"no CI push run on main for {snap.sha}")
    if runs[0].status != "completed":
        raise Refusal("CI_RUNNING", f"CI is {runs[0].status}: {runs[0].url}")
    if runs[0].conclusion != "success":
        raise Refusal("CI_FAILED", f"CI concluded {runs[0].conclusion}: {runs[0].url}")


def _emit(**fields: object) -> None:
    print(TypeAdapter(dict[str, object]).dump_json(fields, by_alias=True).decode())


def _refuse(refusal: Refusal, exit_code: int = 1) -> int:
    _emit(ok=False, errorCode=refusal.error_code, message=str(refusal))
    return exit_code


app = App(
    name="release",
    result_action="return_value",
    version_flags=[],
    print_error=False,
    exit_on_error=False,
)


@app.command
def compute(bump: Bump, /) -> int:
    """Print the next release's version, SHA and commits, after the release gates.

    Args:
        bump: patch, minor or major.

    Returns:
        The exit code.
    """
    try:
        snap = snapshot()
        version = next_version(snap.previous_tag, bump)
        require_releasable(snap, f"v{version}")
    except Refusal as refusal:
        return _refuse(refusal)
    _emit(
        ok=True,
        bump=bump,
        version=str(version),
        tag=f"v{version}",
        sha=snap.sha,
        previousTag=snap.previous_tag,
        commits=[commit.model_dump(by_alias=True) for commit in snap.commits],
    )
    return 0


@app.command
def release(*, version: str, sha: str, notes_file: str, yes: bool = False) -> int:
    """Re-check what `compute` returned, then, with --yes, create the tag and Release.

    Args:
        version: The version `compute` printed.
        sha: The SHA `compute` printed.
        notes_file: The release notes, in Markdown.
        yes: Create the release; without it, only report.

    Returns:
        The exit code.
    """
    try:
        inputs = _ReleaseInput(version=version, sha=sha, notes_file=Path(notes_file))
    except ValidationError as error:
        return _refuse(Refusal("BAD_INPUT", str(error)))
    tag = f"v{inputs.version}"
    try:
        snap = snapshot()
        versions = {str(next_version(snap.previous_tag, b)) for b in get_args(Bump)}
        if inputs.sha != snap.sha or inputs.version not in versions:
            raise Refusal(
                "STALE",
                f"compute now gives {sorted(versions)} at {snap.sha}; rerun compute",
            )
        require_releasable(snap, tag)
        url = None
        if yes:
            url = _run(
                "gh", "release", "create", tag, "--target", snap.sha, "--title", tag,
                "--notes-file", str(inputs.notes_file),
            ).strip()  # fmt: skip
    except Refusal as refusal:
        return _refuse(refusal)
    _emit(
        ok=True,
        dryRun=not yes,
        version=inputs.version,
        tag=tag,
        sha=snap.sha,
        notesFile=str(inputs.notes_file),
        url=url,
    )
    return 0


def main() -> int:
    """Run the CLI.

    Returns:
        The exit code.
    """
    try:
        return app()
    except CycloptsError as error:
        return _refuse(Refusal("USAGE", str(error)), exit_code=2)


if __name__ == "__main__":
    sys.exit(main())
