#!/usr/bin/env -S uv run --script
# Keep the shebang, requires-python and pins in sync with release.py.
# /// script
# requires-python = ">=3.12"
# dependencies = ["cyclopts==5.2.0", "pydantic==2.14.1", "semver==3.1.0"]
# ///
"""Tests for the release script's version math, gates and parsing."""

import json
import unittest
from dataclasses import replace
from typing import get_args

from release import (
    Bump,
    CiRun,
    Commit,
    ErrorCode,
    Refusal,
    Refused,
    Snapshot,
    candidates,
    latest_tag,
    next_version,
    remote_tags,
    require_releasable,
)

SHA = "a" * 40
RELEASABLE = Snapshot(
    sha=SHA,
    previous_tag="v0.1.0",
    commits=(Commit(sha=SHA, subject="feat: x"),),
    remote_tags={"v0.1.0": "b" * 40},
    ci_run=CiRun(status="completed", conclusion="success", url="https://ci/1"),
)


class NextVersionTest(unittest.TestCase):
    """next_version bumps from the previous tag."""

    def test_first_release_is_0_1_0_for_every_bump(self):
        """With no tag, every bump gives 0.1.0."""
        for bump in get_args(Bump):
            with self.subTest(bump=bump):
                self.assertEqual(str(next_version(None, bump)), "0.1.0")

    def test_bumps_from_previous_tag(self):
        """Each bump moves its own component and resets the lower ones."""
        cases: dict[Bump, str] = {"patch": "0.1.1", "minor": "0.2.0", "major": "1.0.0"}
        for bump, want in cases.items():
            with self.subTest(bump=bump):
                self.assertEqual(str(next_version("v0.1.0", bump)), want)


class CandidatesTest(unittest.TestCase):
    """candidates lists every version compute could have printed."""

    def test_no_tag_gives_only_the_first_version(self):
        """Before the first release, every bump agrees on 0.1.0."""
        self.assertEqual(candidates(None), {"0.1.0"})

    def test_one_per_bump_after_a_tag(self):
        """After a tag, each bump gives its own version."""
        self.assertEqual(candidates("v0.1.0"), {"0.1.1", "0.2.0", "1.0.0"})


class LatestTagTest(unittest.TestCase):
    """latest_tag picks the highest v<semver> tag."""

    def test_ignores_tags_that_are_not_v_semver(self):
        """Tags without a v prefix or a full semver are skipped."""
        self.assertEqual(latest_tag(["vnext", "v1.2", "1.0.0", "v0.1.0"]), "v0.1.0")

    def test_ranks_by_semver_precedence(self):
        """v0.10.0 outranks v0.9.0, which a string sort would not."""
        self.assertEqual(latest_tag(["v0.9.0", "v0.10.0"]), "v0.10.0")

    def test_no_tags_gives_none(self):
        """An empty tag list has no latest tag."""
        self.assertIsNone(latest_tag([]))


class RemoteTagsTest(unittest.TestCase):
    """remote_tags maps each tag in ls-remote output to its commit."""

    def test_annotated_tag_resolves_to_its_peeled_commit(self):
        """The `^{}` line names the commit an annotated tag points at."""
        output = f"{'1' * 40}\trefs/tags/v0.2.0\n{'2' * 40}\trefs/tags/v0.2.0^{{}}\n"
        self.assertEqual(remote_tags(output), {"v0.2.0": "2" * 40})

    def test_lightweight_tag_keeps_its_commit(self):
        """A tag without a peeled line already names its commit."""
        self.assertEqual(
            remote_tags(f"{'3' * 40}\trefs/tags/v0.1.0\n"), {"v0.1.0": "3" * 40}
        )

    def test_empty_output_gives_no_tags(self):
        """An origin without tags lists nothing."""
        self.assertEqual(remote_tags(""), {})


class RequireReleasableTest(unittest.TestCase):
    """require_releasable refuses a snapshot that must not be released."""

    def assert_refuses(self, code: ErrorCode, snapshot: Snapshot, tag: str = "v0.2.0"):
        """Assert the gate refuses `snapshot` with `code`."""
        with self.assertRaises(Refusal) as raised:
            require_releasable(snapshot, tag)
        self.assertIs(raised.exception.code, code)

    def test_passes_with_commits_a_free_tag_and_green_ci(self):
        """A releasable snapshot passes every gate."""
        require_releasable(RELEASABLE, "v0.2.0")

    def test_no_commits(self):
        """Nothing since the previous tag is NO_COMMITS."""
        self.assert_refuses(ErrorCode.NO_COMMITS, replace(RELEASABLE, commits=()))

    def test_tag_exists(self):
        """A tag origin already has is TAG_EXISTS."""
        self.assert_refuses(ErrorCode.TAG_EXISTS, RELEASABLE, tag="v0.1.0")

    def test_ci_no_run(self):
        """No CI run for the SHA is CI_NO_RUN."""
        self.assert_refuses(ErrorCode.CI_NO_RUN, replace(RELEASABLE, ci_run=None))

    def test_ci_running(self):
        """A CI run still in progress is CI_RUNNING."""
        run = CiRun(status="in_progress", conclusion=None, url="https://ci/1")
        self.assert_refuses(ErrorCode.CI_RUNNING, replace(RELEASABLE, ci_run=run))

    def test_ci_failed(self):
        """A completed CI run that did not succeed is CI_FAILED."""
        run = CiRun(status="completed", conclusion="failure", url="https://ci/1")
        self.assert_refuses(ErrorCode.CI_FAILED, replace(RELEASABLE, ci_run=run))


class EnvelopeTest(unittest.TestCase):
    """The envelopes print the camelCase keys the skill reads."""

    def test_refused_prints_ok_error_code_and_message(self):
        """A refusal prints ok, errorCode and message."""
        refused = Refused(error_code=ErrorCode.STALE, message="rerun compute")
        self.assertEqual(
            json.loads(refused.model_dump_json()),
            {"ok": False, "errorCode": "STALE", "message": "rerun compute"},
        )


class ExitCodeTest(unittest.TestCase):
    """Each refusal maps to the script's exit code."""

    def test_usage_exits_2_and_every_other_refusal_1(self):
        """A usage error exits 2; every other refusal exits 1."""
        for code in ErrorCode:
            with self.subTest(code=code):
                self.assertEqual(code.exit_code, 2 if code is ErrorCode.USAGE else 1)


if __name__ == "__main__":
    unittest.main()
