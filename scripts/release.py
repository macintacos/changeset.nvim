#!/usr/bin/env -S uv run --script
# Keep requires-python and the pins in sync with test_release.py, and requires-python
# with ruff.toml's target-version.
# /// script
# requires-python = ">=3.12"
# dependencies = ["cyclopts==5.2.0", "pydantic==2.14.1", "semver==3.1.0"]
# ///
"""Compute and cut a changeset.nvim release of origin/main, printing one JSON object.

Exits 0 on success, 1 on a refusal, 2 on a usage error; the object is `Computed`,
`Released` or `Refused`.
"""

import shutil
import subprocess
import sys
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from enum import StrEnum
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
RELEASE_BRANCH: Final = "main"
# Keep in sync with .github/workflows/ci.yml: its `name:` and its push trigger.
CI_WORKFLOW: Final = "CI"


class ErrorCode(StrEnum):
    """Why the script refused."""

    USAGE = "USAGE"
    BAD_INPUT = "BAD_INPUT"
    NO_GH = "NO_GH"
    GH_UNAUTHENTICATED = "GH_UNAUTHENTICATED"
    NO_COMMITS = "NO_COMMITS"
    TAG_EXISTS = "TAG_EXISTS"
    CI_NO_RUN = "CI_NO_RUN"
    CI_RUNNING = "CI_RUNNING"
    CI_FAILED = "CI_FAILED"
    STALE = "STALE"
    COMMAND_FAILED = "COMMAND_FAILED"

    @property
    def exit_code(self) -> int:
        """The script's exit status for this refusal."""
        return 2 if self is ErrorCode.USAGE else 1


@dataclass
class Refusal(Exception):
    """A reason the script stops, reported as the `ok: false` envelope."""

    code: ErrorCode
    message: str


def latest_tag(tags: Iterable[str]) -> str | None:
    """The highest `v<semver>` tag by precedence, or None when there is none.

    Args:
        tags: Tag names, without the `refs/tags/` prefix.
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
        previous_tag: As `latest_tag` returns it: `v` plus valid semver, or None
            before the first release.
        bump: Which component to bump.
    """
    if previous_tag is None:
        return FIRST_VERSION
    return semver.Version.parse(previous_tag[1:]).next_version(bump)


def candidates(previous_tag: str | None) -> set[str]:
    """Every version `compute` can give after `previous_tag`.

    Args:
        previous_tag: As `latest_tag` returns it, or None before the first release.
    """
    return {str(next_version(previous_tag, bump)) for bump in get_args(Bump)}


def remote_tags(ls_remote: str) -> dict[str, str]:
    """Map each tag in `git ls-remote --tags` output to the commit it names.

    Args:
        ls_remote: The command's stdout; an annotated tag's `^{}` line wins.
    """
    tags: dict[str, str] = {}
    for line in ls_remote.splitlines():
        sha, ref = line.split("\t")
        tag = ref.removeprefix("refs/tags/")
        if tag.endswith("^{}"):
            tags[tag.removesuffix("^{}")] = sha
        else:
            tags.setdefault(tag, sha)
    return tags


class _Envelope(BaseModel):
    model_config = ConfigDict(
        alias_generator=to_camel, serialize_by_alias=True, validate_by_name=True
    )


class Commit(_Envelope):
    """A commit the release would ship."""

    sha: str
    subject: str


class Computed(_Envelope):
    """What `compute` prints: the next release."""

    ok: Literal[True] = True
    bump: Bump
    version: str
    tag: str
    sha: str
    previous_tag: str | None
    commits: tuple[Commit, ...]


class Released(_Envelope):
    """What `release` prints: the release created, or with `dry_run` the one it would."""

    ok: Literal[True] = True
    dry_run: bool
    version: str
    tag: str
    sha: str
    notes_file: Path
    url: str | None


class Refused(_Envelope):
    """What either command prints when it refuses."""

    ok: Literal[False] = False
    error_code: ErrorCode
    message: str


class CiRun(BaseModel):
    """The latest CI run on a commit, as `gh run list` reports it."""

    status: str
    conclusion: str | None
    url: str


def _non_empty(path: Path) -> Path:
    if path.stat().st_size == 0:
        raise ValueError("the notes file is empty")
    return path.resolve()


class _ReleaseInput(BaseModel):
    version: Annotated[str, AfterValidator(lambda v: str(semver.Version.parse(v)))]
    sha: Annotated[str, Field(pattern=r"^[0-9a-f]{40}$")]
    notes_file: Annotated[FilePath, AfterValidator(_non_empty)]


@dataclass(frozen=True, slots=True)
class Snapshot:
    """What origin says the next release would contain."""

    sha: str
    previous_tag: str | None
    commits: tuple[Commit, ...]
    remote_tags: Mapping[str, str]
    ci_run: CiRun | None


def require_releasable(snap: Snapshot, tag: str) -> None:
    """Refuse unless there are commits, `tag` is free, and CI passed on the SHA.

    Args:
        snap: The snapshot to release.
        tag: The tag the release would create.

    Raises:
        Refusal: When a gate fails.
    """
    if not snap.commits:
        raise Refusal(ErrorCode.NO_COMMITS, f"no commits follow {snap.previous_tag}")
    if tag in snap.remote_tags:
        raise Refusal(ErrorCode.TAG_EXISTS, f"{tag} already exists on origin")
    run = snap.ci_run
    if run is None:
        raise Refusal(
            ErrorCode.CI_NO_RUN,
            f"no {CI_WORKFLOW} push run on {RELEASE_BRANCH} for {snap.sha}",
        )
    if run.status != "completed":
        raise Refusal(ErrorCode.CI_RUNNING, f"CI is {run.status}: {run.url}")
    if run.conclusion != "success":
        raise Refusal(ErrorCode.CI_FAILED, f"CI concluded {run.conclusion}: {run.url}")


def _run(*args: str) -> str:
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != 0:
        raise Refusal(
            ErrorCode.COMMAND_FAILED, f"{' '.join(args)}: {result.stderr.strip()}"
        )
    return result.stdout


def _require_gh() -> None:
    if shutil.which("gh") is None:
        raise Refusal(ErrorCode.NO_GH, "gh is not on PATH")
    # Plain status: with --json it always exits 0.
    auth = subprocess.run(["gh", "auth", "status"], capture_output=True, text=True)
    if auth.returncode != 0:
        raise Refusal(
            ErrorCode.GH_UNAUTHENTICATED, auth.stderr.strip() or "gh is not logged in"
        )


def _log_commits(span: str) -> tuple[Commit, ...]:
    log = _run("git", "log", "--format=%H%x1f%s", span)
    return tuple(
        Commit(sha=sha, subject=subject)
        for sha, subject in (line.split("\x1f", 1) for line in log.splitlines())
    )


def _ci_run(sha: str) -> CiRun | None:
    runs_json = _run(
        "gh",
        "run",
        "list",
        "--workflow",
        CI_WORKFLOW,
        "--branch",
        RELEASE_BRANCH,
        "--event",
        "push",
        "--commit",
        sha,
        "--json",
        "status,conclusion,url",
        "--limit",
        "1",
    )
    return next(iter(TypeAdapter(list[CiRun]).validate_json(runs_json)), None)


def read_snapshot() -> Snapshot:
    """Read origin's release branch, its tags, the commits since the latest, and CI.

    Fetches origin's release branch; changes no local ref but its remote-tracking one.
    """
    _require_gh()
    # An explicit refspec, so a narrowed remote.origin.fetch can't leave the SHA stale.
    _run(
        "git",
        "fetch",
        "--no-tags",
        "origin",
        f"+refs/heads/{RELEASE_BRANCH}:refs/remotes/origin/{RELEASE_BRANCH}",
    )
    sha = _run("git", "rev-parse", f"origin/{RELEASE_BRANCH}").strip()
    tags = remote_tags(_run("git", "ls-remote", "--tags", "origin", "refs/tags/v*"))
    previous = latest_tag(tags)
    span = f"{tags[previous]}..{sha}" if previous else sha
    return Snapshot(sha, previous, _log_commits(span), tags, _ci_run(sha))


app = App(
    name="release",
    result_action="return_value",
    version_flags=[],
    print_error=False,
    exit_on_error=False,
)


@app.command
def compute(bump: Bump, /) -> int:
    """Print the next release's version, SHA and commits, once the release gates pass.

    Args:
        bump: Which component to bump.
    """
    snap = read_snapshot()
    version = str(next_version(snap.previous_tag, bump))
    tag = f"v{version}"
    require_releasable(snap, tag)
    computed = Computed(
        bump=bump,
        version=version,
        tag=tag,
        sha=snap.sha,
        previous_tag=snap.previous_tag,
        commits=snap.commits,
    )
    print(computed.model_dump_json())
    return 0


@app.command
def release(*, version: str, sha: str, notes_file: str, yes: bool = False) -> int:
    """Re-check what `compute` returned, then, with --yes, create the tag and Release.

    Args:
        version: The version `compute` printed.
        sha: The SHA `compute` printed.
        notes_file: The release notes, in Markdown.
        yes: Create the release; without it, only report.
    """
    try:
        inputs = _ReleaseInput(version=version, sha=sha, notes_file=Path(notes_file))
    except ValidationError as error:
        raise Refusal(ErrorCode.BAD_INPUT, str(error)) from error
    tag = f"v{inputs.version}"
    snap = read_snapshot()
    versions = candidates(snap.previous_tag)
    if inputs.sha != snap.sha or inputs.version not in versions:
        raise Refusal(
            ErrorCode.STALE,
            f"compute now gives {', '.join(sorted(versions))} at {snap.sha}; "
            "rerun compute",
        )
    require_releasable(snap, tag)
    url = None
    if yes:
        url = _run(
            "gh",
            "release",
            "create",
            tag,
            "--target",
            snap.sha,
            "--title",
            tag,
            "--notes-file",
            str(inputs.notes_file),
        ).strip()
    released = Released(
        dry_run=not yes,
        version=inputs.version,
        tag=tag,
        sha=snap.sha,
        notes_file=inputs.notes_file,
        url=url,
    )
    print(released.model_dump_json())
    return 0


def main() -> int:
    """Run the CLI, printing a `Refused` envelope for any refusal.

    Returns:
        0, or the refusal's exit code.
    """
    try:
        return app()
    except CycloptsError as error:
        refusal = Refusal(ErrorCode.USAGE, str(error))
    except Refusal as raised:
        refusal = raised
    print(Refused(error_code=refusal.code, message=refusal.message).model_dump_json())
    return refusal.code.exit_code


if __name__ == "__main__":
    sys.exit(main())
