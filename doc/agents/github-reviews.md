# GitHub reviews

This doc records what GitHub's pending-review API accepts, and the `gh api` calls that
drive it. The measurements ran on 2026-10-03, with `gh` 2.102.0, against a sandbox pull
request.

## The sandbox

Every measurement here ran against pull request 1 in the private repository
`macintacos/changeset-nvim-review-sandbox`:
<https://github.com/macintacos/changeset-nvim-review-sandbox/pull/1>. The pull request
merges `sandbox-pr` into `main`.

On `main`, `alpha.txt` holds 40 lines, `alpha 01` to `alpha 40`, and `beta.txt` holds 20
lines, `beta 01` to `beta 20`. `sandbox-pr` makes one commit on top:

- In `alpha.txt`, it changes line 10 to `alpha 10 changed`, and adds `alpha 30a` and
  `alpha 30b` after old line 30, so they become new lines 31 and 32.
- In `beta.txt`, it changes line 3 to `beta 03 changed`, and adds `beta 15a` after old
  line 15, so it becomes new line 16.

GitHub's diff carries 3 lines of context, so its hunks are wider than the `--unified=0`
hunks that `lua/changeset/diff.lua` parses into `changeset.Hunk`. The table gives both
kinds of hunk in line numbers of the new file, `sandbox-pr`:

| File | `gh pr diff` hunk | New lines it covers | `changeset.Hunk` |
| --- | --- | --- | --- |
| `alpha.txt` | `@@ -7,7 +7,7 @@` | 7-13 | `lnum = 10, count = 1` |
| `alpha.txt` | `@@ -28,6 +28,8 @@` | 28-35 | `lnum = 31, count = 2` |
| `beta.txt` | `@@ -1,6 +1,6 @@` | 1-6 | `lnum = 3, count = 1` |
| `beta.txt` | `@@ -13,6 +13,7 @@` | 13-19 | `lnum = 16, count = 1` |

Lines 14 to 27 of `alpha.txt` sit between its two hunks, outside both.

`git diff -U3 main sandbox-pr`, run in a local clone of the sandbox, produced the same
headers as `gh pr diff`. For each hunk above, git's `-U3` extent follows from the `-U0`
hunk by this arithmetic:

```text
count > 0  →  new-side extent lnum-3 .. lnum+count+2
count = 0  →  new-side extent lnum-2 .. lnum+3        (pure deletion, unverified; lnum is N in +N,0)
clamp every extent to 1 .. #lines; merge extents that overlap or abut
```

The sandbox has no pure deletion and no hunks close enough to merge, so only the
`count > 0` row and the clamp are checked against git.

To rebuild the sandbox, run these commands from a scratch directory:

- `sed` must be GNU `sed`. On macOS, install Homebrew's `gnu-sed` and put its `gnubin`
  directory first on `PATH`, because BSD
  `sed -i` takes different arguments.
- The repository must not exist yet, so that `gh repo create` succeeds and the pull
  request gets number 1.

```sh
gh repo create macintacos/changeset-nvim-review-sandbox --private
git init -q -b main EXC-1555-sandbox && cd EXC-1555-sandbox
for i in $(seq -w 1 40); do echo "alpha $i"; done > alpha.txt
for i in $(seq -w 1 20); do echo "beta $i"; done > beta.txt
git add . && git commit -qm "Add alpha.txt and beta.txt"
git switch -qc sandbox-pr
sed -i -e 's/^alpha 10$/alpha 10 changed/' -e '/^alpha 30$/a alpha 30a\nalpha 30b' alpha.txt
sed -i -e 's/^beta 03$/beta 03 changed/' -e '/^beta 15$/a beta 15a' beta.txt
git commit -qam "Change and add lines in alpha.txt and beta.txt"
git remote add origin https://github.com/macintacos/changeset-nvim-review-sandbox.git
git push -q -u origin main sandbox-pr
gh pr create -R macintacos/changeset-nvim-review-sandbox --base main --head sandbox-pr \
  --title "Sandbox PR for review-comment experiments" \
  --body "Throwaway PR: two hunks in alpha.txt and two in beta.txt, for testing which lines GitHub's pending-review API accepts."
gh pr diff 1 -R macintacos/changeset-nvim-review-sandbox
```
