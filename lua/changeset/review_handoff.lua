---`:Changeset review submit`, `restore`, `yank` and `abandon` and `:Changeset comment list`, which act on the whole
---Review: paste it into an agent's prompt, bring a submitted batch back, copy it, clear it, or list it.
local Paths = require("changeset.paths")
local comment_store = require("changeset.comment_store")
local config = require("changeset.config")
local dialog = require("changeset.dialog")
local highlights = require("changeset.highlights")
local origin = require("changeset.origin")
local review_comment = require("changeset.review_comment")
local review_text = require("changeset.review_text")

local M = {}

---The repository to act on, as `origin.current` answers it.
---@return string
local function root()
  return origin.current().repository
end

---@param level integer
---@param text string
local function say(level, text, ...)
  vim.notify("Changeset: " .. text:format(...), level)
end

---"1 draft", "2 drafts".
---@param n integer
---@return string
local function drafts_label(n)
  return n == 1 and "1 draft" or ("%d drafts"):format(n)
end

---"1 review comment", "2 review comments".
---@param n integer
---@return string
local function comments_label(n)
  return n == 1 and "1 review comment" or ("%d review comments"):format(n)
end

---`comments` split into the saved ones and how many are drafts.
---@param comments changeset.ReviewComment[]
---@return changeset.ReviewComment[] saved, integer drafts
local function split_drafts(comments)
  local saved = vim.tbl_filter(function(comment)
    return not comment.draft
  end, comments)
  return saved, #comments - #saved
end

---`comments` in the order every view lists them in.
---@param comments changeset.ReviewComment[]
---@return changeset.ReviewComment[]
local function in_order(comments)
  local sorted = vim.list_slice(comments)
  table.sort(sorted, review_comment.before)
  return sorted
end

---Asks, then deletes every review comment of the repository.
function M.abandon()
  local repository = root()
  local comments = comment_store.list(repository)
  local count, drafts = #comments, select(2, split_drafts(comments))
  if count == 0 then
    return say(vim.log.levels.INFO, "no review to abandon in %s", repository)
  end
  local name = vim.fs.basename(repository)
  dialog.confirm({
    title = "Abandon the review",
    body = {
      {
        text = count == 1 and ("Deletes the %sreview comment in %s. It can't be brought back."):format(
          drafts == 1 and "draft " or "",
          name
        ) or ("Deletes all %d review comments in %s%s. They can't be brought back."):format(
          count,
          name,
          drafts == 0 and "" or ("; %d %s a draft"):format(drafts, drafts == 1 and "is" or "are")
        ),
      },
    },
    action = "Abandon",
  }, function()
    if not comment_store.drop_all(repository) then
      return say(vim.log.levels.ERROR, "can't abandon the review in %s", comment_store.path())
    end
    say(vim.log.levels.INFO, "abandoned the review")
  end)
end

-- How long a submit counts as in flight with no answer: past herdr's round trips, for a picker closed under
-- `noautocmd`, whose callback never comes.
local SUBMIT_TIMEOUT = 20000

---The submit being delivered, if any; a second waits for it rather than pasting the same review twice.
---@type table?
local submitting

---Ends the submit `this` started, unless a later one already took its place.
---@param this table
local function release(this)
  if submitting == this then
    submitting = nil
  end
end

---The repository's saved review comments, how many drafts it holds, and the text they are pasted as; nothing after
---saying why when none is saved to `verb`.
---@param repository string
---@param verb string
---@return changeset.ReviewComment[]? comments
---@return integer drafts
---@return string text
local function saved_review(repository, verb)
  local comments, drafts = split_drafts(comment_store.list(repository))
  if #comments == 0 then
    if drafts > 0 then
      say(vim.log.levels.INFO, "nothing saved to %s, only %s", verb, drafts_label(drafts))
    else
      say(vim.log.levels.INFO, "no review comments to %s", verb)
    end
    return nil, drafts, ""
  end
  return comments, drafts, review_text.text(repository, comments, config.get().review)
end

---Pastes the repository's saved review comments into an agent's prompt through herdr, then takes the ones pasted out
---of the store, where `restore` can bring them back. Drafts stay.
function M.submit()
  local repository = root()
  local comments, drafts, text = saved_review(repository, "submit")
  if not comments then
    return
  end
  local staying = drafts > 0 and ("; %s %s"):format(drafts_label(drafts), drafts == 1 and "stays" or "stay") or ""
  local count = comments_label(#comments)
  if submitting then
    return say(vim.log.levels.INFO, "a submit is already going")
  end
  local this = {}
  submitting = this
  vim.defer_fn(function()
    release(this)
  end, SUBMIT_TIMEOUT)
  require("changeset.herdr").send(text, { title = "Submit " .. count, root = repository }, function(err, agent)
    release(this)
    if err then
      return say(vim.log.levels.WARN, "can't submit the review: %s", err)
    end
    if not agent then
      return
    end
    -- Only what went: a comment written or edited while the pick was open stays.
    if not comment_store.take(repository, { comments = comments, at = os.time(), to = agent }) then
      return say(
        vim.log.levels.WARN,
        "pasted %s into %s's prompt, but %s still listed: can't remove %s from %s",
        count,
        agent,
        #comments == 1 and "it is" or "they are",
        #comments == 1 and "it" or "them",
        comment_store.path()
      )
    end
    say(
      vim.log.levels.INFO,
      "submitted %s to %s; :Changeset review restore brings %s back%s",
      count,
      agent,
      #comments == 1 and "it" or "them",
      staying
    )
  end)
end

---Brings back `batch`, one the repository's branch submitted, and says how it went.
---@param repository string
---@param batch changeset.SubmittedBatch
local function restore_batch(repository, batch)
  local restored, kept = comment_store.restore(repository, batch)
  if not restored then
    return say(vim.log.levels.ERROR, "can't restore the review comments in %s", comment_store.path())
  end
  if restored + kept == 0 then
    return say(vim.log.levels.INFO, "that batch is no longer submitted in %s", repository)
  end
  if kept == 0 then
    return say(vim.log.levels.INFO, "restored %s", comments_label(restored))
  end
  local staying = kept == 1 and "stays submitted: its lines hold a newer one"
    or "stay submitted: their lines hold newer ones"
  if restored == 0 then
    return say(vim.log.levels.INFO, "%s %s", comments_label(kept), staying)
  end
  say(vim.log.levels.INFO, "restored %s; %d %s", comments_label(restored), kept, staying)
end

---A row of the restore picker: when `batch` went and to whom, how many it holds, and its first comment.
---@param batch changeset.SubmittedBatch
---@return changeset.DialogItem
local function batch_row(batch)
  local first = in_order(batch.comments)[1]
  return {
    cells = {
      {
        batch.at and os.date("%b %d %H:%M", batch.at) --[[@as string]] or "",
        highlights.META_HL,
      },
      { batch.to or "" },
      { comments_label(#batch.comments) },
      { first and ("%s  %s"):format(review_comment.location(first), first.body:match("^[^\r\n]*")) or "" },
    },
  }
end

---Brings back a batch of review comments the repository's branch submitted, as saved ones, leaving out any on lines
---that hold a review comment now: the only one, or the one picked, newest first.
function M.restore()
  local repository = root()
  local batches = comment_store.submitted(repository)
  if not batches then
    return say(vim.log.levels.ERROR, "can't restore the review comments in %s", comment_store.path())
  end
  if #batches == 0 then
    return say(vim.log.levels.INFO, "no submitted review comments to restore in %s", repository)
  end
  if #batches == 1 then
    return restore_batch(repository, batches[1])
  end
  dialog.choose({
    title = "Restore submitted review comments",
    items = vim.tbl_map(batch_row, batches),
    action = "restore",
  }, function(index)
    if index then
      restore_batch(repository, assert(batches[index], "changeset: a choice past the batches"))
    end
  end)
end

local QF_TITLE = "Changeset review comments"

---Puts the repository's review comments in the quickfix list, replacing the one this made last if still current.
function M.list()
  local repository = root()
  local comments = in_order(comment_store.list(repository))
  if #comments == 0 then
    return say(vim.log.levels.INFO, "no review comments in %s", repository)
  end
  local items = vim.tbl_map(function(comment)
    local body = vim.split(comment.body, "\n")
    return {
      filename = vim.fs.joinpath(repository, comment.path),
      lnum = review_comment.first(comment) or 0,
      end_lnum = comment.line,
      text = (comment.draft and "[draft] " or "") .. (#body > 1 and body[1] .. " …" or body[1]),
    }
  end, comments)
  local action = vim.fn.getqflist({ title = 0 }).title == QF_TITLE and "r" or " "
  vim.fn.setqflist({}, action, { title = QF_TITLE, items = items })
  vim.cmd.copen()
end

---Copies the review's saved comments, as `submit` would paste them, as `Paths.put` does, keeping the comments.
function M.yank()
  local repository = root()
  local comments, drafts, text = saved_review(repository, "copy")
  if not comments then
    return
  end
  local where = Paths.put(text)
  local left_out = drafts > 0 and ("; %s left out"):format(drafts_label(drafts)) or ""
  say(vim.log.levels.INFO, "copied %s%s%s", comments_label(#comments), where, left_out)
end

return M
