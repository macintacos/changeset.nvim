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

## Lines a review comment accepts

A line review comment needs both ends inside GitHub's hunks. `line`, and `startLine` when
the review comment covers a range, must each fall on a new-side line of some hunk in
`gh pr diff`, context lines included. The lines between them may leave the hunks: a range
from one hunk into the next is accepted.

GitHub refuses any other line silently. `addPullRequestReviewThread` exits 0 with
`"thread": null` and no `errors`, and stores no review comment, so a caller must treat a
null `thread` as a refusal. For a line outside every hunk, a file-level review comment
works instead: pass `subjectType: FILE` with no `line`.

To decide from `changeset.Hunk`, which carries no context, widen each hunk to GitHub's
extent. Only one part of this mapping was measured on GitHub: that its hunks are git's
`-U3` hunks, which the rows for lines 13 and 14 below and the hunk table in
§ The sandbox show. The arithmetic itself is git's `-U3` arithmetic, from § The sandbox:

```text
count > 0  →  new-side extent lnum-3 .. lnum+count+2
count = 0  →  new-side extent lnum-2 .. lnum+3        (pure deletion, unverified)
clamp every extent to 1 .. #lines; merge extents that overlap or abut
```

Every row below ran against one pending review on pull request 1, with `side: RIGHT`
and a body naming the case. A row counts as accepted only when the mutation returned a
thread and the listed review comment kept the `line` and `startLine` asked for, which
`tests/fixtures/github-reviews/pending-review-comments.json` shows for every accepted
row. Before the matrix, the find query returned no pending review
(`tests/fixtures/github-reviews/find-pending-review-empty.json`), and
`addPullRequestReview` created the pending review
(`tests/fixtures/github-reviews/add-pending-review.json`).

| Case | Path | `startLine` | `line` | Accepted when added | Kept at submit | GitHub's error | Fixture |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Added line | `alpha.txt` | — | 31 | yes | yes | — | `tests/fixtures/github-reviews/add-thread-added-line.json` |
| Last context line of a hunk | `alpha.txt` | — | 13 | yes | yes | — | `tests/fixtures/github-reviews/add-thread-context-line.json` |
| First line past a hunk's context | `alpha.txt` | — | 14 | no | — | `thread: null`, no error | `tests/fixtures/github-reviews/add-thread-outside-hunk.json` |
| Range over changed and context lines in one hunk | `alpha.txt` | 8 | 10 | yes | yes | — | `tests/fixtures/github-reviews/add-thread-range-in-hunk.json` |
| Range over two hunks | `alpha.txt` | 10 | 31 | yes | yes | — | `tests/fixtures/github-reviews/add-thread-range-two-hunks.json` |
| Range from outside a hunk into a changed line | `alpha.txt` | 4 | 10 | no | — | `thread: null`, no error | `tests/fixtures/github-reviews/add-thread-range-from-outside.json` |
| Line deep outside any hunk | `alpha.txt` | — | 20 | no | — | `thread: null`, no error | `tests/fixtures/github-reviews/add-thread-deep-outside-hunk.json` |
| File-level, `subjectType: FILE` | `alpha.txt` | — | — | yes | yes | — | `tests/fixtures/github-reviews/add-thread-file-level.json` |
| Added line in a second file | `beta.txt` | — | 16 | yes | yes | — | `tests/fixtures/github-reviews/add-thread-beta-added-line.json` |

The mutation's `thread` reports `startLine` equal to `line` for a single-line review
comment, but the review comment itself stores `startLine: null`. For the file-level
review comment, `thread.line` reads 1 while the review comment's `line` is null. Read
lines from the review comment, not the thread.

§ Calls gives the calls that ran. Every accepted review comment kept its `line` and
`startLine` once the pending review was submitted
(`tests/fixtures/github-reviews/submitted-review-comments.json`).

## Calls

Drive every pending-review operation through GraphQL with node IDs. A numeric ID, where
one is needed, is `fullDatabaseId`, which arrives as a JSON string; never request the
deprecated `databaseId`. Pass user text as a `-f` variable, never inside the query. A
GraphQL call that fails exits 1, prints its `{"errors":…}` body on stdout, and prints
`gh: <message>` on stderr.

| Operation | API | ID kind | Result | Fixture |
| --- | --- | --- | --- | --- |
| Find the viewer's pending review, none open | GraphQL | node | `nodes: []` | `tests/fixtures/github-reviews/find-pending-review-empty.json` |
| Find the viewer's pending review | GraphQL | node | one `PENDING` node, `author.login` equal to `viewer.login` | `tests/fixtures/github-reviews/find-pending-review.json` |
| Create a pending review | GraphQL | node | `state: PENDING` | `tests/fixtures/github-reviews/add-pending-review.json` |
| Add a line review comment | GraphQL | node | a thread, or `thread: null` when refused (§ Lines a review comment accepts) | `tests/fixtures/github-reviews/add-thread-range-in-hunk.json` |
| Add a file-level review comment | GraphQL | node | a thread with `subjectType: FILE` | `tests/fixtures/github-reviews/add-thread-file-level.json` |
| List review comments, page 1 of 3 | GraphQL | node | 2 nodes, `hasNextPage: true` | `tests/fixtures/github-reviews/review-comments-page-1.json` |
| List review comments, page 2 of 3 | GraphQL | node | 2 nodes, `hasNextPage: true` | `tests/fixtures/github-reviews/review-comments-page-2.json` |
| List review comments, page 3 of 3 | GraphQL | node | 2 nodes, `hasNextPage: false` | `tests/fixtures/github-reviews/review-comments-page-3.json` |
| List review comments with `--paginate --slurp` | GraphQL | node | an array of the same 3 pages | `tests/fixtures/github-reviews/review-comments-paginate-slurp.json` |
| Delete a review comment | GraphQL | node | the pending review's `id` | `tests/fixtures/github-reviews/delete-review-comment.json` |
| List review comments after the delete | GraphQL | node | 5 nodes, the deleted one gone | `tests/fixtures/github-reviews/review-comments-after-delete.json` |
| Delete the pending review | GraphQL | node | `state: PENDING`, the state it had | `tests/fixtures/github-reviews/delete-pending-review.json` |
| Find after deleting the pending review | GraphQL | node | `nodes: []` | `tests/fixtures/github-reviews/find-pending-review-after-delete.json` |
| Create a pending review, no `event` | REST | numeric `id`, plus `node_id` | `state: PENDING` | `tests/fixtures/github-reviews/rest-create-pending-review.json` |
| Find the REST-created pending review | GraphQL | node | the same review, `id` equal to REST's `node_id` | `tests/fixtures/github-reviews/find-pending-review-rest-created.json` |
| List reviews | REST | numeric `id` | the same review, `state: PENDING` | `tests/fixtures/github-reviews/rest-list-reviews.json` |
| Delete the REST-created pending review | GraphQL | node | `state: PENDING` | `tests/fixtures/github-reviews/delete-rest-created-review.json` |
| Find a pending review started on github.com | GraphQL | node | hand check pending; the pull request body gives its steps | — |
| Submit | GraphQL | node | § Submitting | `tests/fixtures/github-reviews/submit-comment-with-body.json` |
| List a submitted review's comments | GraphQL | node | the lines asked for | `tests/fixtures/github-reviews/submitted-review-comments.json` |

GitHub shows a pending review only to its author, so `states: PENDING` returns at most
the viewer's own. One account can't show whether `states: PENDING` alone would exclude
another user's pending review, so the find query relies on GitHub hiding them. Compare
`author.login` with `viewer.login` to be safe.

`gh api graphql --paginate --slurp` follows the `comments` cursor nested under `node` by
itself. It needs `$endCursor` declared and `pageInfo { hasNextPage endCursor }` selected,
and prints one JSON array holding every page. With page size 2 on six review comments, it
returned the same three pages as the hand-driven calls.

The calls, with `<…>` standing for a value from an earlier response:

```sh
gh api graphql -f owner=macintacos -f name=changeset-nvim-review-sandbox -F number=1 -f query='
query($owner: String!, $name: String!, $number: Int!) {
  viewer { login }
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      id headRefOid viewerDidAuthor
      reviews(states: PENDING, first: 1) { nodes { id fullDatabaseId state commit { oid } author { login } } }
    }
  }
}'

gh api graphql -f pr=<pullRequest.id> -f query='
mutation($pr: ID!) {
  addPullRequestReview(input: {pullRequestId: $pr}) { pullRequestReview { id fullDatabaseId state commit { oid } } }
}'

gh api graphql -f review=<review id> -f path=alpha.txt -F startLine=8 -F line=10 -f body=<text> -f query='
mutation($review: ID!, $path: String!, $line: Int!, $startLine: Int, $body: String!) {
  addPullRequestReviewThread(input: {pullRequestReviewId: $review, path: $path, line: $line, side: RIGHT, startLine: $startLine, body: $body}) {
    thread { id isOutdated line startLine comments(first: 1) { nodes { id fullDatabaseId line startLine } } }
  }
}'

gh api graphql -f review=<review id> -f path=alpha.txt -f body=<text> -f query='
mutation($review: ID!, $path: String!, $body: String!) {
  addPullRequestReviewThread(input: {pullRequestReviewId: $review, path: $path, subjectType: FILE, body: $body}) {
    thread { id isOutdated line startLine subjectType comments(first: 1) { nodes { id fullDatabaseId line startLine subjectType } } }
  }
}'

gh api graphql --paginate --slurp -f review=<review id> -f query='
query($review: ID!, $endCursor: String) {
  node(id: $review) { ... on PullRequestReview {
    comments(first: 2, after: $endCursor) {
      pageInfo { hasNextPage endCursor }
      nodes { id fullDatabaseId path line startLine originalLine originalStartLine outdated commit { oid } originalCommit { oid } diffHunk body }
    }
  } }
}'

gh api graphql -f id=<review comment id> -f query='
mutation($id: ID!) { deletePullRequestReviewComment(input: {id: $id}) { pullRequestReview { id } } }'

gh api graphql -f review=<review id> -f query='
mutation($review: ID!) { deletePullRequestReview(input: {pullRequestReviewId: $review}) { pullRequestReview { id state } } }'

gh api graphql -f review=<review id> -f event=COMMENT -f body=<text> -f query='
mutation($review: ID!, $event: PullRequestReviewEvent!, $body: String) {
  submitPullRequestReview(input: {pullRequestReviewId: $review, event: $event, body: $body}) { pullRequestReview { id state body } }
}'

gh api graphql -f review=<review id> -f query='
query($review: ID!) {
  node(id: $review) { ... on PullRequestReview {
    state
    comments(first: 20) {
      nodes { id fullDatabaseId path line startLine originalLine originalStartLine outdated subjectType }
    }
  } }
}'

gh api -X POST repos/macintacos/changeset-nvim-review-sandbox/pulls/1/reviews -f commit_id=<headRefOid>
gh api repos/macintacos/changeset-nvim-review-sandbox/pulls/1/reviews
```

To list one page at a time, drop `--paginate --slurp` and pass `-f endCursor=<endCursor>`
for every page after the first. The REST create passes no `event`, which leaves the review
pending.

## Submitting

Submit with `submitPullRequestReview` and an `event` of `COMMENT`, `REQUEST_CHANGES`, or
`APPROVE`. A `COMMENT` needs a body or at least one review comment. On the viewer's own
pull request, GitHub refuses `REQUEST_CHANGES` and `APPROVE` whatever the body. A refused
submit leaves the pending review and its review comments as they were, so the caller can
fix the input and submit again, or delete the pending review.

Every case started from a fresh pending review on pull request 1, which the viewer
authored:

| Event | Review comments | Body | Exit | Result | Fixture |
| --- | --- | --- | --- | --- | --- |
| `COMMENT` | the six accepted in § Lines a review comment accepts | yes | 0 | `state: COMMENTED` | `tests/fixtures/github-reviews/submit-comment-with-body.json` |
| `COMMENT` | 1 | no | 0 | `state: COMMENTED`, `body: ""` | `tests/fixtures/github-reviews/submit-comment-one-review-comment-no-body.json` |
| `COMMENT` | 0 | no | 1 | `Could not comment for pull request review. You need to leave a comment indicating the requested changes.` | `tests/fixtures/github-reviews/submit-comment-empty.json`, `tests/fixtures/github-reviews/submit-comment-empty.stderr` |
| `REQUEST_CHANGES` | 1 | no | 1 | `Could not request_changes for pull request review. Can not request changes on your own pull request` | `tests/fixtures/github-reviews/submit-request-changes-no-body.json`, `tests/fixtures/github-reviews/submit-request-changes-no-body.stderr` |
| `REQUEST_CHANGES` | 1 | yes | 1 | `Could not request_changes for pull request review. Can not request changes on your own pull request` | `tests/fixtures/github-reviews/submit-request-changes-with-body.json`, `tests/fixtures/github-reviews/submit-request-changes-with-body.stderr` |
| `APPROVE` | 1 | no | 1 | `Could not approve for pull request review. Can not approve your own pull request` | `tests/fixtures/github-reviews/submit-approve.json`, `tests/fixtures/github-reviews/submit-approve.stderr` |

The empty `COMMENT`'s message names requested changes, though the event was `COMMENT`.
Match a refusal on the `errors` array's `type: UNPROCESSABLE`, not on its message.

The own-PR error hides whether `REQUEST_CHANGES` needs a body, so that rule is unmeasured.

After each refused submit, the find query still returned the pending review, and listing
it returned its one review comment. The run then deleted it with `deletePullRequestReview`:

| Refused case | Find after | Review comments after | Delete |
| --- | --- | --- | --- |
| `COMMENT`, empty | `tests/fixtures/github-reviews/find-after-submit-comment-empty.json` | — | `tests/fixtures/github-reviews/delete-after-submit-comment-empty.json` |
| `REQUEST_CHANGES`, no body | `tests/fixtures/github-reviews/find-after-submit-request-changes-no-body.json` | `tests/fixtures/github-reviews/review-comments-after-submit-request-changes-no-body.json` | `tests/fixtures/github-reviews/delete-after-submit-request-changes-no-body.json` |
| `REQUEST_CHANGES`, body | `tests/fixtures/github-reviews/find-after-submit-request-changes-with-body.json` | `tests/fixtures/github-reviews/review-comments-after-submit-request-changes-with-body.json` | `tests/fixtures/github-reviews/delete-after-submit-request-changes-with-body.json` |
| `APPROVE` | `tests/fixtures/github-reviews/find-after-submit-approve.json` | `tests/fixtures/github-reviews/review-comments-after-submit-approve.json` | `tests/fixtures/github-reviews/delete-after-submit-approve.json` |

## When the PR's head moves

A pending review stays pinned to the commit it was created on, and its review comments
follow their lines into the new head where GitHub can still find them. A review comment
whose line moved but kept its text keeps `outdated: false`, gets the new line number in
`line`, and moves its `commit` to the new head. A review comment whose line was edited or
deleted goes `outdated: true` with `line: null`, and keeps the old commit; only
`originalLine` still says where it was. Submitting changes none of this. A review comment
added after the move resolves `line` against the new head's diff, even though the pending
review's own `commit` stays the old one. So read a review comment's position from `line`
and `commit`, treat `line: null` as outdated, and send new review comments in new-head line
numbers.

The run used pull request 2 in the sandbox,
<https://github.com/macintacos/changeset-nvim-review-sandbox/pull/2>, which merged
`head-moves` into `main` and is now closed. Its first commit, `78ed3ec`, changed lines 10,
20, and 30 of `alpha.txt` to `alpha NN changed`, giving hunks `@@ -7,7 +7,7 @@`,
`@@ -17,7 +17,7 @@`, and `@@ -27,7 +27,7 @@`. `addPullRequestReview` created the pending
review on `78ed3ec` (`tests/fixtures/github-reviews/head-moves-add-pending-review.json`),
and one review comment went on each changed line
(`tests/fixtures/github-reviews/head-moves-add-thread-10.json`,
`tests/fixtures/github-reviews/head-moves-add-thread-20.json`,
`tests/fixtures/github-reviews/head-moves-add-thread-30.json`,
`tests/fixtures/github-reviews/head-moves-comments-before.json`).

A second commit, `9822b1d`, pushed as a fast-forward, inserted two lines at the top of
`alpha.txt`, so `alpha 10 changed` moved to line 12, edited `alpha 20 changed` to
`alpha 20 changed again`, and deleted `alpha 30 changed`. Listing the pending review's
comments again gave:

| Review comment on | `line` | `originalLine` | `outdated` | `commit` | `originalCommit` |
| --- | --- | --- | --- | --- | --- |
| `alpha 10 changed`, moved | 12 | 10 | false | `9822b1d` | `78ed3ec` |
| `alpha 20 changed`, edited | null | 20 | true | `78ed3ec` | `78ed3ec` |
| `alpha 30 changed`, deleted | null | 30 | true | `78ed3ec` | `78ed3ec` |

Every `diffHunk` stayed the one from `78ed3ec`
(`tests/fixtures/github-reviews/head-moves-comments-after-push.json`). The find query
still returned the pending review with `commit` `78ed3ec`, while `headRefOid` was
`9822b1d` (`tests/fixtures/github-reviews/head-moves-find-after-push.json`).

A review comment then added at line 12 was accepted
(`tests/fixtures/github-reviews/head-moves-add-thread-after-push.json`). Listed, it had
`line` and `originalLine` 12, `commit` and `originalCommit` `9822b1d`, and the `diffHunk`
`@@ -7,7 +9,7 @@`, a header from the new head's diff
(`tests/fixtures/github-reviews/head-moves-comments-after-add.json`). Line 12 lies in the
first hunk of both diffs, so acceptance alone could not tell them apart; the header does.

Submitting as `COMMENT` with a body succeeded
(`tests/fixtures/github-reviews/head-moves-submit.json`). The four review comments listed
afterwards with the same `line`, `originalLine`, `outdated`, and commits as before
(`tests/fixtures/github-reviews/head-moves-comments-after-submit.json`).

§ Calls gives the calls; the listing ran with `--paginate --slurp`, so each listing fixture
is an array of pages.
