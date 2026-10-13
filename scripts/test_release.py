#!/usr/bin/env -S uv run --script
# Keep the shebang, requires-python and pins in sync with release.py.
# /// script
# requires-python = ">=3.12"
# dependencies = ["cyclopts==5.2.0", "pydantic==2.14.1", "semver==3.1.0"]
# ///
"""Tests for the release script's version math."""

import unittest

from release import Bump, latest_tag, next_version


class NextVersionTest(unittest.TestCase):
    """next_version bumps from the previous tag."""

    def test_first_release_is_0_1_0_for_every_bump(self):
        """With no tag, every bump gives 0.1.0."""
        for bump in ("patch", "minor", "major"):
            with self.subTest(bump=bump):
                self.assertEqual(str(next_version(None, bump)), "0.1.0")

    def test_bumps_from_previous_tag(self):
        """Each bump moves its own component and resets the lower ones."""
        cases: dict[Bump, str] = {"patch": "0.1.1", "minor": "0.2.0", "major": "1.0.0"}
        for bump, want in cases.items():
            with self.subTest(bump=bump):
                self.assertEqual(str(next_version("v0.1.0", bump)), want)


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


if __name__ == "__main__":
    unittest.main()
