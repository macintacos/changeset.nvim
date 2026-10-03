# GitHub pending-review rules

These rules apply to a change that reads or writes a GitHub pending review or its review
comments through `gh api`. They come from calls measured on 2026-10-03 with `gh` 2.102.0
against a sandbox pull request, which § The sandbox describes.

## Lines a review comment accepts

`line`, and `startLine` for a range, must each fall on a new-side line of a hunk in
`gh pr diff`, context lines included. The lines between may leave the hunks, so a range
from one hunk into the next is accepted. A range with either end outside every hunk is
refused.

GitHub refuses an in-file line outside the hunks silently. `addPullRequestReviewThread`
exits 0 with `"thread": null` and no `errors`, and stores no review comment, so a caller
must treat a null `thread` as a refusal. A line past the end of the file, and a path not in
the pull request, are unmeasured. For a line outside every hunk, a file-level review
comment works instead: pass `subjectType: FILE` with no `line`.

To decide from `changeset.Hunk`, which carries no context, use this predicate:

```text
new-side line L is commentable iff some changeset.Hunk h has
  count > 0:  h.lnum - 3 <= L <= h.lnum + h.count + 2
  count = 0:  h.lnum - 2 <= L <= h.lnum + 3     (lnum is N in +N,0)
```

- The `count > 0` row was checked against `git diff -U3` and against `gh pr diff 1`, whose
  hunks are git's `-U3` hunks. The rows for lines 13 and 14 below pin the context edge.
- The `count = 0` row was checked against git, and against pull request 2's live
  pure-deletion hunk `@@ -27,7 +29,6 @@`, whose `-U0` form `+31,0` predicts lines 29-34.
- No review comment was ever placed on a deletion's context, so acceptance there is
  unmeasured.

The predicate holds only while the file's `changeset.Hunk`s diff the pull request's base
against `pullRequest.headRefOid`: the working-tree file must match the head, and the base
must match. GitHub resolves `line` against the current head, never the pending review's
`commit` (§ When the pull request's head moves). Whether git's diff algorithm and GitHub's
split every edit the same way is unmeasured, because the sandbox's edits are ones every
algorithm agrees on.

Every call sent `side: RIGHT`, except the file-level one, which sent no `side`. The old
side, `LEFT`, is unmeasured. A single-line review comment omitted `-F startLine`; passing
`startLine` equal to `line` is unmeasured.

The rows below ran on pull request 1, each with a body naming the case. The mirror row ran
on a pending review of its own
(`tests/fixtures/github-reviews/mirror-range-add-pending-review.json`), and every other row
on one shared pending review. A row counts as accepted only when the mutation returned a
thread and the listed review comment kept the `line` and `startLine` asked for, which
`tests/fixtures/github-reviews/pending-review-comments.json` shows for every accepted row.
That pending review was then deleted, so "Kept at submit" means the same cases, re-added to
a fresh pending review, then submitted
(`tests/fixtures/github-reviews/submitted-review-comments.json`).

| Case | Path | `startLine` | `line` | Accepted when added | Kept at submit | GitHub's error | Fixture |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Added line | `alpha.txt` | — | 31 | yes | yes | — | `tests/fixtures/github-reviews/add-thread-added-line.json` |
| Last context line of a hunk | `alpha.txt` | — | 13 | yes | yes | — | `tests/fixtures/github-reviews/add-thread-context-line.json` |
| First line past a hunk's context | `alpha.txt` | — | 14 | no | — | `thread: null`, no error | `tests/fixtures/github-reviews/add-thread-outside-hunk.json` |
| Range over changed and context lines in one hunk | `alpha.txt` | 8 | 10 | yes | yes | — | `tests/fixtures/github-reviews/add-thread-range-in-hunk.json` |
| Range over two hunks | `alpha.txt` | 10 | 31 | yes | yes | — | `tests/fixtures/github-reviews/add-thread-range-two-hunks.json` |
| Range from outside a hunk into a changed line | `alpha.txt` | 4 | 10 | no | — | `thread: null`, no error | `tests/fixtures/github-reviews/add-thread-range-from-outside.json` |
| Range from a changed line out of its hunk | `alpha.txt` | 10 | 20 | no | — | `thread: null`, no error | `tests/fixtures/github-reviews/add-thread-range-into-gap.json` |
| Line deep outside any hunk | `alpha.txt` | — | 20 | no | — | `thread: null`, no error | `tests/fixtures/github-reviews/add-thread-deep-outside-hunk.json` |
| File-level, `subjectType: FILE` | `alpha.txt` | — | — | yes | yes | — | `tests/fixtures/github-reviews/add-thread-file-level.json` |
| Added line in a second file | `beta.txt` | — | 16 | yes | yes | — | `tests/fixtures/github-reviews/add-thread-beta-added-line.json` |

`addPullRequestReviewThread` returns a thread wrapping the new review comment. Keep the
review comment's `id` (`PRRC_…`), which `deletePullRequestReviewComment` takes, not the
thread's (`PRRT_…`). The thread reports `startLine` equal to `line` for a single-line
review comment, but the review comment itself stores `startLine: null`. For the file-level
review comment, `thread.line` reads 1 while the review comment's `line` is null. Read lines
from the review comment, not the thread.

A file-level review comment lists with `line: null`, `outdated: false`, and `diffHunk: ""`.
The listing can also select `subjectType`, which returns `LINE` or `FILE`
(`tests/fixtures/github-reviews/submitted-review-comments.json`).

## Resolving the pull request

Resolve the pull request from the checkout with
`gh pr view --json author,baseRefName,headRefOid,number,state,url`. Take every later call's
host, owner and name from `url`, and its number from `number`. Pass the host to `gh api`
as `--hostname`, since `gh api` never infers it from the checkout.

`url` names the base repository from a fork's checkout too. Measured on `cli/cli` pull
request 14474, whose head branch lives on a fork (`isCrossRepository: true`): after
`gh pr checkout 14474` in a clone of `cli/cli`, `url` named `cli/cli`, not the fork.

## Calls

Run the find query first, and create a pending review only when it returns none. GitHub
allows one pending review per user per pull request: a second `addPullRequestReview` exits
1 with `User can only have one pending review per pull request`
(`tests/fixtures/github-reviews/second-add-pending-review.json`,
`tests/fixtures/github-reviews/second-add-pending-review.stderr`), and the find query
afterwards still returned the one pending review
(`tests/fixtures/github-reviews/find-after-second-add-pending-review.json`). That was the
mirror row's pending review, which held no review comment, and the run deleted it
(`tests/fixtures/github-reviews/delete-after-second-add-pending-review.json`).

`viewerDidAuthor: true` means GitHub will refuse `REQUEST_CHANGES` and `APPROVE`
(§ Submitting).

Drive every pending-review operation through GraphQL with node IDs. A numeric ID, where one
is needed, is `fullDatabaseId`, which arrives as a JSON string; never request the
deprecated `databaseId`. Pass user text as a `-f` variable, never inside the query.

A GraphQL call that fails exits 1, prints its `{"errors":…}` body on stdout, and prints
`gh: <message>` on stderr. Treat exit 1, or any `errors` entry, as a failure. Every refusal
here carried `type: UNPROCESSABLE`, but another failure, such as a stale node ID, may carry
another `type`, and the message isn't reliable for telling refusals apart.

| Operation | API | ID kind | Result | Fixture |
| --- | --- | --- | --- | --- |
| Find the viewer's pending review, none open | GraphQL | node | `nodes: []` | `tests/fixtures/github-reviews/find-pending-review-empty.json` |
| Find the viewer's pending review | GraphQL | node | one `PENDING` node, `author.login` equal to `viewer.login` | `tests/fixtures/github-reviews/find-pending-review.json` |
| Find a pending review started on github.com | GraphQL | node | hand check pending; the steps follow this table | — |
| Create a pending review | GraphQL | node | `state: PENDING` | `tests/fixtures/github-reviews/add-pending-review.json` |
| Add a line review comment | GraphQL | node | a thread, or `thread: null` when refused (§ Lines a review comment accepts) | `tests/fixtures/github-reviews/add-thread-range-in-hunk.json` |
| Add a file-level review comment | GraphQL | node | a thread with `subjectType: FILE` | `tests/fixtures/github-reviews/add-thread-file-level.json` |
| List review comments, page 1 of 3 | GraphQL | node | 2 nodes, `hasNextPage: true` | `tests/fixtures/github-reviews/review-comments-page-1.json` |
| List review comments, page 2 of 3 | GraphQL | node | 2 nodes, `hasNextPage: true` | `tests/fixtures/github-reviews/review-comments-page-2.json` |
| List review comments, page 3 of 3 | GraphQL | node | 2 nodes, `hasNextPage: false` | `tests/fixtures/github-reviews/review-comments-page-3.json` |
| List review comments with `--paginate --slurp` | GraphQL | node | an array of the same 3 pages | `tests/fixtures/github-reviews/review-comments-paginate-slurp.json` |
| Delete a review comment | GraphQL | node | the pending review's `id` | `tests/fixtures/github-reviews/delete-review-comment.json` |
| Delete the pending review | GraphQL | node | `state: PENDING`, the state it had | `tests/fixtures/github-reviews/delete-pending-review.json` |
| Submit | GraphQL | node | § Submitting | `tests/fixtures/github-reviews/submit-comment-with-body.json` |

To hand-check finding a pending review started on github.com:

1. Open sandbox pull request 1 on github.com.
2. Add a review comment on `alpha.txt` line 31 with **Start a review**, and don't submit
   it.
3. Run the find query below verbatim, and expect one `PENDING` node. List its review
   comments, and expect the line-31 one.
4. Optionally, try dragging a range from `alpha.txt` line 4 to line 10 on github.com, and
   note whether the UI allows it. The API refused that range.
5. Discard the pending review on github.com.
6. Replace the table's row with the result.

The find query assumes GitHub shows a pending review only to its author, so
`states: PENDING` returns at most the viewer's own. One account can't test that
assumption.

`gh api graphql --paginate --slurp` follows the `comments` cursor nested under `node` by
itself. It needs `$endCursor` declared and `pageInfo { hasNextPage endCursor }` selected,
and prints one JSON array holding every page. With page size 2 on six review comments, it
returned the same three pages as the hand-driven calls. The run used `first: 2` to force
pagination; use up to `first: 100`, GitHub's maximum page size for a connection.

The calls, with `<…>` standing for a value from an earlier response:

```sh
gh api graphql -f owner=macintacos -f name=changeset-nvim-review-sandbox -F number=1 -f query='query($owner: String!, $name: String!, $number: Int!) {
  viewer { login }
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      id headRefOid viewerDidAuthor
      reviews(states: PENDING, first: 1) { nodes { id fullDatabaseId state commit { oid } author { login } } }
    }
  }
}'

gh api graphql -f pr=<pullRequest.id> -f query='mutation($pr: ID!) {
  addPullRequestReview(input: {pullRequestId: $pr}) { pullRequestReview { id fullDatabaseId state commit { oid } } }
}'

# For a single line, omit -F startLine.
gh api graphql -f review=<pending review id> -f path=alpha.txt -F startLine=8 -F line=10 -f body=<text> -f query='mutation($review: ID!, $path: String!, $line: Int!, $startLine: Int, $body: String!) {
  addPullRequestReviewThread(input: {pullRequestReviewId: $review, path: $path, line: $line, side: RIGHT, startLine: $startLine, body: $body}) {
    thread { id isOutdated line startLine comments(first: 1) { nodes { id fullDatabaseId line startLine } } }
  }
}'

gh api graphql -f review=<pending review id> -f path=alpha.txt -f body=<text> -f query='mutation($review: ID!, $path: String!, $body: String!) {
  addPullRequestReviewThread(input: {pullRequestReviewId: $review, path: $path, subjectType: FILE, body: $body}) {
    thread { id isOutdated line startLine subjectType comments(first: 1) { nodes { id fullDatabaseId line startLine subjectType } } }
  }
}'

gh api graphql --paginate --slurp -f review=<pending review id> -f query='query($review: ID!, $endCursor: String) {
  node(id: $review) { ... on PullRequestReview {
    comments(first: 2, after: $endCursor) {
      pageInfo { hasNextPage endCursor }
      nodes { id fullDatabaseId path line startLine originalLine originalStartLine outdated commit { oid } originalCommit { oid } diffHunk body }
    }
  } }
}'

gh api graphql -f id=<review comment id> -f query='mutation($id: ID!) { deletePullRequestReviewComment(input: {id: $id}) { pullRequestReview { id } } }'

gh api graphql -f review=<pending review id> -f query='mutation($review: ID!) { deletePullRequestReview(input: {pullRequestReviewId: $review}) { pullRequestReview { id state } } }'

gh api graphql -f review=<pending review id> -f event=COMMENT -f body=<text> -f query='mutation($review: ID!, $event: PullRequestReviewEvent!, $body: String) {
  submitPullRequestReview(input: {pullRequestReviewId: $review, event: $event, body: $body}) { pullRequestReview { id state body } }
}'
```

To list one page at a time, drop `--paginate --slurp` and pass `-f endCursor=<endCursor>`
for every page after the first. Run that way at a page size above the node count, the
listing returns one page, as in `tests/fixtures/github-reviews/pending-review-comments.json`
and the three `review-comments-after-submit-*` fixtures in § Submitting.

### Checks the run made

These calls verified the contract above; no change needs them.

| Check | API | ID kind | Result | Fixture |
| --- | --- | --- | --- | --- |
| List review comments after the delete | GraphQL | node | 5 nodes, the deleted one gone | `tests/fixtures/github-reviews/review-comments-after-delete.json` |
| Find after deleting the pending review | GraphQL | node | `nodes: []` | `tests/fixtures/github-reviews/find-pending-review-after-delete.json` |
| Create a pending review, no `event` | REST | numeric `id`, plus `node_id` | `state: PENDING` | `tests/fixtures/github-reviews/rest-create-pending-review.json` |
| Find the REST-created pending review | GraphQL | node | the same pending review, `id` equal to REST's `node_id` | `tests/fixtures/github-reviews/find-pending-review-rest-created.json` |
| List reviews | REST | numeric `id` | the same pending review, `state: PENDING` | `tests/fixtures/github-reviews/rest-list-reviews.json` |
| Delete the REST-created pending review | GraphQL | node | `state: PENDING` | `tests/fixtures/github-reviews/delete-rest-created-review.json` |
| List a submitted pending review's review comments | GraphQL | node | the lines asked for | `tests/fixtures/github-reviews/submitted-review-comments.json` |

With no `event`, the REST create makes a pending review and does not submit it. The
post-submit listing used `comments(first: 20)` with no `pageInfo`, so it stops at 20:

```sh
gh api graphql -f review=<pending review id> -f query='query($review: ID!) {
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

## Submitting

Submit with `submitPullRequestReview` and an `event` of `COMMENT`, `REQUEST_CHANGES`, or
`APPROVE`. A `COMMENT` with neither a body nor a review comment is refused; one with a body
alone, or with one review comment alone, succeeds. On the viewer's own pull request, GitHub
refused `REQUEST_CHANGES` and `APPROVE` both with and without a body. A refused submit
leaves the pending review and its review comments in place, and submitting the same
pending review again with a body succeeded.

Every case started from a fresh pending review on pull request 1, which the viewer
authored:

| Event | Review comments | Body | Exit | Result | Fixture |
| --- | --- | --- | --- | --- | --- |
| `COMMENT` | the six accepted in § Lines a review comment accepts | yes | 0 | `state: COMMENTED` | `tests/fixtures/github-reviews/submit-comment-with-body.json` |
| `COMMENT` | 1 | no | 0 | `state: COMMENTED`, `body: ""` | `tests/fixtures/github-reviews/submit-comment-one-review-comment-no-body.json` |
| `COMMENT` | 0 | no | 1 | `Could not comment for pull request review. You need to leave a comment indicating the requested changes.` | `tests/fixtures/github-reviews/submit-comment-empty.json`, `tests/fixtures/github-reviews/submit-comment-empty.stderr` |
| `COMMENT`, then resubmitted | 0 | no, then yes | 1, then 0 | refused as above, then `state: COMMENTED` with the body | `tests/fixtures/github-reviews/resubmit-comment-empty.json`, `tests/fixtures/github-reviews/resubmit-comment-empty.stderr`, `tests/fixtures/github-reviews/resubmit-comment-body-only.json` |
| `REQUEST_CHANGES` | 1 | no | 1 | `Could not request_changes for pull request review. Can not request changes on your own pull request` | `tests/fixtures/github-reviews/submit-request-changes-no-body.json`, `tests/fixtures/github-reviews/submit-request-changes-no-body.stderr` |
| `REQUEST_CHANGES` | 1 | yes | 1 | `Could not request_changes for pull request review. Can not request changes on your own pull request` | `tests/fixtures/github-reviews/submit-request-changes-with-body.json`, `tests/fixtures/github-reviews/submit-request-changes-with-body.stderr` |
| `APPROVE` | 1 | no | 1 | `Could not approve for pull request review. Can not approve your own pull request` | `tests/fixtures/github-reviews/submit-approve.json`, `tests/fixtures/github-reviews/submit-approve.stderr` |
| `APPROVE` | 1 | yes | 1 | `Could not approve for pull request review. Can not approve your own pull request` | `tests/fixtures/github-reviews/submit-approve-with-body.json`, `tests/fixtures/github-reviews/submit-approve-with-body.stderr` |

The resubmitted case's pending review came from
`tests/fixtures/github-reviews/resubmit-add-pending-review.json`. The `APPROVE` with a body
case's came from `tests/fixtures/github-reviews/approve-with-body-add-pending-review.json`,
and its review comment, on `alpha.txt` line 31, from
`tests/fixtures/github-reviews/approve-with-body-add-thread.json`.

The empty `COMMENT`'s message names requested changes, though the event was `COMMENT`. The
own-pull-request error hides whether `REQUEST_CHANGES` needs a body, so that rule is
unmeasured.

After each refused submit below, the find query still returned the pending review. For the
three listed afterwards, listing returned the review comment. The run then deleted it with
`deletePullRequestReview`:

| Refused case | Find after | Review comments after | Delete |
| --- | --- | --- | --- |
| `COMMENT`, empty | `tests/fixtures/github-reviews/find-after-submit-comment-empty.json` | — | `tests/fixtures/github-reviews/delete-after-submit-comment-empty.json` |
| `REQUEST_CHANGES`, no body | `tests/fixtures/github-reviews/find-after-submit-request-changes-no-body.json` | `tests/fixtures/github-reviews/review-comments-after-submit-request-changes-no-body.json` | `tests/fixtures/github-reviews/delete-after-submit-request-changes-no-body.json` |
| `REQUEST_CHANGES`, body | `tests/fixtures/github-reviews/find-after-submit-request-changes-with-body.json` | `tests/fixtures/github-reviews/review-comments-after-submit-request-changes-with-body.json` | `tests/fixtures/github-reviews/delete-after-submit-request-changes-with-body.json` |
| `APPROVE`, no body | `tests/fixtures/github-reviews/find-after-submit-approve.json` | `tests/fixtures/github-reviews/review-comments-after-submit-approve.json` | `tests/fixtures/github-reviews/delete-after-submit-approve.json` |
| `APPROVE`, body | `tests/fixtures/github-reviews/find-after-submit-approve-with-body.json` | — | `tests/fixtures/github-reviews/delete-after-submit-approve-with-body.json` |

## When the pull request's head moves

Read a review comment's position from its `line` and `commit`; treat `outdated: true` as
outdated (its `line` is null). Send new review comments in the line numbers of
`headRefOid`, never of the pending review's `commit`.

When the head moves, the pending review keeps the commit it was created on, but its review
comments follow their lines into the new head:

- A review comment whose line moved with its text unchanged keeps `outdated: false`. Its
  `line` becomes the new line number, and its `commit` becomes the new head.
- A review comment whose line was edited or deleted goes `outdated: true` with
  `line: null`, and keeps the old `commit`. Only `originalLine` still says where it was.
- A review comment added after the move resolves `line` against the new head's diff. The
  find query just before the add still showed the pending review's `commit` as the old one.

Submitting the pending review changes none of this.

The run used pull request 2 in the sandbox,
<https://github.com/macintacos/changeset-nvim-review-sandbox/pull/2>, which asked to merge
`head-moves` into `main` and was closed without merging. Its first commit, `78ed3ec`,
changed lines 10, 20, and 30 of `alpha.txt` to `alpha NN changed`, giving hunks
`@@ -7,7 +7,7 @@`, `@@ -17,7 +17,7 @@`, and `@@ -27,7 +27,7 @@`. `addPullRequestReview`
created the pending review on `78ed3ec`
(`tests/fixtures/github-reviews/head-moves-add-pending-review.json`), and one review comment
went on each changed line (`tests/fixtures/github-reviews/head-moves-add-thread-10.json`,
`tests/fixtures/github-reviews/head-moves-add-thread-20.json`,
`tests/fixtures/github-reviews/head-moves-add-thread-30.json`,
`tests/fixtures/github-reviews/head-moves-comments-before.json`).

A second commit, `9822b1d`, pushed as a fast-forward, inserted two lines at the top of
`alpha.txt`, so `alpha 10 changed` moved to line 12, edited `alpha 20 changed` to
`alpha 20 changed again`, and deleted `alpha 30 changed`. Listing the pending review's
review comments again gave:

| Review comment on | `line` | `originalLine` | `outdated` | `commit` | `originalCommit` |
| --- | --- | --- | --- | --- | --- |
| `alpha 10 changed`, moved | 12 | 10 | false | `9822b1d` | `78ed3ec` |
| `alpha 20 changed`, edited | null | 20 | true | `78ed3ec` | `78ed3ec` |
| `alpha 30 changed`, deleted | null | 30 | true | `78ed3ec` | `78ed3ec` |

Every `diffHunk` stayed the one from `78ed3ec`
(`tests/fixtures/github-reviews/head-moves-comments-after-push.json`). The find query still
returned the pending review with `commit` `78ed3ec`, while `headRefOid` was `9822b1d`
(`tests/fixtures/github-reviews/head-moves-find-after-push.json`).

A review comment then added at line 12 was accepted
(`tests/fixtures/github-reviews/head-moves-add-thread-after-push.json`). Listed, it had
`line` and `originalLine` 12, `commit` and `originalCommit` `9822b1d`, and the `diffHunk`
`@@ -7,7 +9,7 @@`, a header from the new head's diff
(`tests/fixtures/github-reviews/head-moves-comments-after-add.json`). Line 12 lies inside a
hunk of both diffs: `@@ -7,7 +7,7 @@` in `78ed3ec`'s and `@@ -7,7 +9,7 @@` in the new
head's. So acceptance alone can't tell which diff GitHub used, but the `diffHunk` header
can.

Submitting as `COMMENT` with a body succeeded
(`tests/fixtures/github-reviews/head-moves-submit.json`). The four review comments listed
afterwards with the same `line`, `originalLine`, `outdated`, and commits as before
(`tests/fixtures/github-reviews/head-moves-comments-after-submit.json`).

## The sandbox

Every measurement ran in the private repository `macintacos/changeset-nvim-review-sandbox`.
Pull request 1, <https://github.com/macintacos/changeset-nvim-review-sandbox/pull/1>,
merges `sandbox-pr` into `main`. § When the pull request's head moves describes pull request
2's commits; it has no rebuild recipe.

On `main`, `alpha.txt` holds 40 lines, `alpha 01` to `alpha 40`, and `beta.txt` holds 20
lines, `beta 01` to `beta 20`. `sandbox-pr` makes one commit on top:

- In `alpha.txt`, it changes line 10 to `alpha 10 changed`, and adds `alpha 30a` and
  `alpha 30b` after old line 30, so they become new lines 31 and 32.
- In `beta.txt`, it changes line 3 to `beta 03 changed`, and adds `beta 15a` after old
  line 15, so it becomes new line 16.

The table gives each hunk of pull request 1 in line numbers of the new file, `sandbox-pr`,
both as GitHub's 3-line-context hunk and as the `--unified=0` `changeset.Hunk` that
`lua/changeset/diff.lua` parses:

| File | `gh pr diff` hunk | New lines it covers | `changeset.Hunk` |
| --- | --- | --- | --- |
| `alpha.txt` | `@@ -7,7 +7,7 @@` | 7-13 | `lnum = 10, count = 1` |
| `alpha.txt` | `@@ -28,6 +28,8 @@` | 28-35 | `lnum = 31, count = 2` |
| `beta.txt` | `@@ -1,6 +1,6 @@` | 1-6 | `lnum = 3, count = 1` |
| `beta.txt` | `@@ -13,6 +13,7 @@` | 13-19 | `lnum = 16, count = 1` |

Lines 14 to 27 of `alpha.txt` sit between its two hunks, outside both.
`git diff -U3 main sandbox-pr`, run in a local clone of the sandbox, produced the same
headers as `gh pr diff`.

To rebuild the sandbox, run these commands from a scratch directory. The repository must
not exist yet, so that `gh repo create` succeeds and the pull request gets number 1.

```sh
gh repo create macintacos/changeset-nvim-review-sandbox --private
git init -q -b main review-sandbox && cd review-sandbox
for i in $(seq -w 1 40); do echo "alpha $i"; done > alpha.txt
for i in $(seq -w 1 20); do echo "beta $i"; done > beta.txt
git add . && git commit -qm "Add alpha.txt and beta.txt"
git switch -qc sandbox-pr
for i in $(seq -w 1 40); do case $i in
  10) echo "alpha 10 changed" ;; 30) printf 'alpha 30\nalpha 30a\nalpha 30b\n' ;; *) echo "alpha $i" ;;
esac; done > alpha.txt
for i in $(seq -w 1 20); do case $i in
  03) echo "beta 03 changed" ;; 15) printf 'beta 15\nbeta 15a\n' ;; *) echo "beta $i" ;;
esac; done > beta.txt
git commit -qam "Change and add lines in alpha.txt and beta.txt"
git remote add origin https://github.com/macintacos/changeset-nvim-review-sandbox.git
git push -q -u origin main sandbox-pr
gh pr create -R macintacos/changeset-nvim-review-sandbox --base main --head sandbox-pr \
  --title "Sandbox PR for review-comment experiments" \
  --body "Throwaway PR: two hunks in alpha.txt and two in beta.txt, for testing which lines GitHub's pending-review API accepts."
gh pr diff 1 -R macintacos/changeset-nvim-review-sandbox
```

## Fixtures

When a spec tests code that parses a `gh` response, load a fixture so the spec reads the
bytes GitHub sent. The fixtures live in `tests/fixtures/github-reviews/`, one file per
recorded call, named for its case. The sections above name the call behind each one:

- `<name>.json` holds the call's raw stdout plus a final newline. For a failed GraphQL
  call, that is the `{"errors":…}` body.
- `<name>.stderr` sits beside it only when the call failed, and holds its stderr verbatim,
  `gh: <message>`. A `.stderr` sibling means `gh` exited 1.

Most fixtures hold one JSON object. These hold a JSON array instead:

- The `--paginate --slurp` listings hold an array of pages, each page one GraphQL
  response: `tests/fixtures/github-reviews/review-comments-paginate-slurp.json`,
  `tests/fixtures/github-reviews/review-comments-after-delete.json`,
  `tests/fixtures/github-reviews/head-moves-comments-before.json`,
  `tests/fixtures/github-reviews/head-moves-comments-after-push.json`,
  `tests/fixtures/github-reviews/head-moves-comments-after-add.json`, and
  `tests/fixtures/github-reviews/head-moves-comments-after-submit.json`.
- The REST listing, `tests/fixtures/github-reviews/rest-list-reviews.json`, holds an array
  of reviews in every state.

Because `tests/minimal_init.lua` puts the repo root on `rtp`, a spec finds a fixture with
`nvim_get_runtime_file` and decodes it:

```lua
local path = vim.api.nvim_get_runtime_file("tests/fixtures/github-reviews/find-pending-review.json", false)[1]
local response = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
```
