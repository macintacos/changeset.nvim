---The branch's pending GitHub review, driven through `gh api`: find, start, comment, delete, submit.
local Git = require("changeset.git")

local M = {}

-- ponytail: a timed-out mutation may still land on GitHub; the next find shows what did
local TIMEOUT = 30000

---@alias changeset.pending_review.Event "COMMENT"|"REQUEST_CHANGES"|"APPROVE"

---@class changeset.pending_review.Pr : changeset.Pr
---@field id string Node ID.
---@field viewer_did_author boolean

---@class changeset.PendingReview
---@field id string Node ID.
---@field comments changeset.ReviewComment[]

---@class changeset.ReviewComment
---@field id string Node ID (`PRRC_…`), never the thread's.
---@field path string
---@field line integer? nil once outdated, or on a file-level review comment.
---@field start_line integer? First line of a range.
---@field body string

---@class changeset.pending_review.Found
---@field pr changeset.pending_review.Pr
---@field review changeset.PendingReview? nil when the viewer has none.

local FIND = [[query($owner: String!, $name: String!, $number: Int!) {
  viewer { login }
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      id headRefOid viewerDidAuthor
      reviews(states: PENDING, first: 1) { nodes { id fullDatabaseId state commit { oid } author { login } } }
    }
  }
}]]

local LIST = [[query($review: ID!, $endCursor: String) {
  node(id: $review) { ... on PullRequestReview {
    comments(first: 100, after: $endCursor) {
      pageInfo { hasNextPage endCursor }
      nodes { id fullDatabaseId path line startLine originalLine originalStartLine outdated commit { oid } originalCommit { oid } diffHunk body }
    }
  } }
}]]

local START = [[mutation($pr: ID!) {
  addPullRequestReview(input: {pullRequestId: $pr}) { pullRequestReview { id fullDatabaseId state commit { oid } } }
}]]

local ADD = [[mutation($review: ID!, $path: String!, $line: Int!, $startLine: Int, $body: String!) {
  addPullRequestReviewThread(input: {pullRequestReviewId: $review, path: $path, line: $line, side: RIGHT, startLine: $startLine, body: $body}) {
    thread { id isOutdated line startLine comments(first: 1) { nodes { id fullDatabaseId line startLine } } }
  }
}]]

local DELETE_COMMENT =
  [[mutation($id: ID!) { deletePullRequestReviewComment(input: {id: $id}) { pullRequestReview { id } } }]]

local DELETE =
  [[mutation($review: ID!) { deletePullRequestReview(input: {pullRequestReviewId: $review}) { pullRequestReview { id state } } }]]

local SUBMIT = [[mutation($review: ID!, $event: PullRequestReviewEvent!, $body: String) {
  submitPullRequestReview(input: {pullRequestReviewId: $review, event: $event, body: $body}) { pullRequestReview { id state body } }
}]]

---Run a GraphQL call; `vars` are `-f`/`-F` pairs in order.
---@param vars string[]
---@param query string
---@param cb fun(err: string?, out: any)
local function graphql(vars, query, cb)
  local args = vim.list_extend({ "api", "graphql" }, vars)
  vim.list_extend(args, { "-f", "query=" .. query })
  Git.gh(args, { timeout = TIMEOUT }, cb)
end

---@return changeset.ReviewComment
local function comment(node)
  return { id = node.id, path = node.path, line = node.line, start_line = node.startLine, body = node.body }
end

---@param pages table[] `--slurp`'s array of listing pages.
---@return changeset.ReviewComment[]
local function comments(pages)
  local out = {}
  for _, page in ipairs(pages) do
    for _, node in ipairs(page.data.node.comments.nodes) do
      table.insert(out, comment(node))
    end
  end
  return out
end

---Find the viewer's pending review on the open PR of the branch checked out at `cwd`.
---@param cwd string?
---@param cb fun(err: string?, found: changeset.pending_review.Found?)
function M.find(cwd, cb)
  Git.pr(cwd, function(err, pr)
    if err then
      return cb(err)
    end
    ---@cast pr changeset.pending_review.Pr
    local vars = { "-f", "owner=" .. pr.owner, "-f", "name=" .. pr.name, "-F", "number=" .. pr.number }
    graphql(vars, FIND, function(find_err, out)
      if find_err then
        return cb(find_err)
      end
      local node = out.data.repository.pullRequest
      pr.id, pr.viewer_did_author = node.id, node.viewerDidAuthor
      local review = node.reviews.nodes[1]
      if not review then
        return cb(nil, { pr = pr })
      end
      Git.gh(
        { "api", "graphql", "--paginate", "--slurp", "-f", "review=" .. review.id, "-f", "query=" .. LIST },
        { timeout = TIMEOUT },
        function(list_err, pages)
          if list_err then
            return cb(list_err)
          end
          cb(nil, { pr = pr, review = { id = review.id, comments = comments(pages) } })
        end
      )
    end)
  end)
end

---Start a pending review on the PR with node ID `pr_id`.
---@param pr_id string
---@param cb fun(err: string?, review: changeset.PendingReview?)
function M.start(pr_id, cb)
  graphql({ "-f", "pr=" .. pr_id }, START, function(err, out)
    if err then
      return cb(err)
    end
    cb(nil, { id = out.data.addPullRequestReview.pullRequestReview.id, comments = {} })
  end)
end

---Add a review comment on `comment.line`, or on `comment.start_line` to `comment.line`.
---@param review_id string
---@param new { path: string, line: integer, start_line: integer?, body: string }
---@param cb fun(err: string?, comment: changeset.ReviewComment?)
function M.add_comment(review_id, new, cb)
  local vars = { "-f", "review=" .. review_id, "-f", "path=" .. new.path, "-F", "line=" .. new.line }
  if new.start_line then
    vim.list_extend(vars, { "-F", "startLine=" .. new.start_line })
  end
  vim.list_extend(vars, { "-f", "body=" .. new.body })
  graphql(vars, ADD, function(err, out)
    if err then
      return cb(err)
    end
    local thread = out.data.addPullRequestReviewThread.thread
    if not thread then
      local lines = new.start_line and ("%d-%d"):format(new.start_line, new.line) or tostring(new.line)
      return cb(("GitHub refused a review comment on %s at line %s"):format(new.path, lines))
    end
    local node = thread.comments.nodes[1]
    cb(nil, { id = node.id, path = new.path, line = node.line, start_line = node.startLine, body = new.body })
  end)
end

---Delete the review comment with node ID `comment_id`.
---@param comment_id string
---@param cb fun(err: string?)
function M.delete_comment(comment_id, cb)
  graphql({ "-f", "id=" .. comment_id }, DELETE_COMMENT, function(err)
    cb(err)
  end)
end

---Delete the pending review with node ID `review_id`, and its review comments.
---@param review_id string
---@param cb fun(err: string?)
function M.delete(review_id, cb)
  graphql({ "-f", "review=" .. review_id }, DELETE, function(err)
    cb(err)
  end)
end

---Submit the pending review with node ID `review_id`.
---@param review_id string
---@param submission { event: changeset.pending_review.Event, body: string? }
---@param cb fun(err: string?)
function M.submit(review_id, submission, cb)
  local vars = { "-f", "review=" .. review_id, "-f", "event=" .. submission.event }
  if submission.body then
    vim.list_extend(vars, { "-f", "body=" .. submission.body })
  end
  graphql(vars, SUBMIT, function(err)
    cb(err)
  end)
end

return M
