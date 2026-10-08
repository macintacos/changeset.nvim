---Review comments kept on this machine, by repository root and the branch each was written on, in a state record,
---beside the batches each branch submitted.
---
---Every mutation re-reads the file and rewrites only its own root's list, so two
---Neovims writing comments don't drop each other's.

local Git = require("changeset.git")
local jsonfile = require("changeset.jsonfile")
local review_comment = require("changeset.review_comment")

local M = {}

---@class changeset.StoredReviewComment : changeset.ReviewComment
---@field branch string? The branch it was written on, or a detached HEAD's commit; nil before branches were recorded.

---@class changeset.SubmittedBatch
---@field comments changeset.ReviewComment[]
---@field at integer? When it was submitted, in seconds since the epoch; nil for one kept before batches recorded it.
---@field to string? The agent it went to; nil as `at` is.

---@type table<fun(), true>
local subscribers = {}

-- The record's key for the batches `take` keeps, by root then branch: no root, an absolute path, is named this.
local TAKEN = "submitted"

-- Every redraw reads the record, so a branch can't keep a batch for every submit.
local KEPT_BATCHES = 10

---Where the record lives. Under `state`, because a comment can't be derived again.
---@return string
function M.path()
  return vim.fs.joinpath(vim.fn.stdpath("state"), "changeset", "comments.json")
end

---A hand edit can leave any JSON value where a comment should be.
---@param entry any
---@return boolean
local function valid(entry)
  return type(entry) == "table"
    and type(entry.path) == "string"
    and type(entry.body) == "string"
    and (entry.line == nil or (type(entry.line) == "number" and entry.line % 1 == 0 and entry.line >= 1))
    and (entry.draft == nil or type(entry.draft) == "boolean")
    and (entry.branch == nil or type(entry.branch) == "string")
    and (
      entry.start_line == nil
      or (
        entry.line ~= nil
        and type(entry.start_line) == "number"
        and entry.start_line % 1 == 0
        and entry.start_line >= 1
        and entry.start_line < entry.line
      )
    )
end

---What the repository at `root` files its comments under: the branch checked out, the one a stopped rebase rewrites,
---else a detached HEAD's commit; nil outside a repository and in a reftable one. Read off git's own files rather than
---by running git, since every redraw and hover asks.
---@param root string
---@return string?
function M.branch(root)
  local dir = Git.git_dir(root)
  local head = Git.first_line(vim.fs.joinpath(dir, "HEAD"))
  -- A reftable repository's HEAD file always names this; only git can say what is checked out.
  if not head or head == "ref: refs/heads/.invalid" then
    return nil
  end
  local name = head:match("^ref: refs/heads/(.+)")
  for _, rebase in ipairs({ "rebase-merge", "rebase-apply" }) do
    name = name or (Git.first_line(vim.fs.joinpath(dir, rebase, "head-name")) or ""):match("^refs/heads/(.+)")
  end
  return name or head
end

---Whether `entry` shows on `branch`: written there, or before branches were recorded.
---@param entry changeset.StoredReviewComment
---@param branch string?
---@return boolean
local function on(entry, branch)
  return entry.branch == nil or entry.branch == branch
end

---The root's entries as stored, malformed ones included.
---@param root string
---@param data table
---@return any[]
local function entries(root, data)
  return type(data[root]) == "table" and data[root] or {}
end

---`data[key]` when it is a table: a hand edit can leave any JSON value there.
---@param data table
---@param key string
---@return table
local function field(data, key)
  return type(data[key]) == "table" and data[key] or {}
end

---A hand edit can leave any JSON value where a batch should be.
---@param batch any
---@return boolean
local function valid_batch(batch)
  return type(batch) == "table"
    and type(batch.comments) == "table"
    and (batch.at == nil or type(batch.at) == "number")
    and (batch.to == nil or type(batch.to) == "string")
end

---The batches `take` kept for `branch` of `root`, newest first, as stored, malformed ones included.
---@param data table
---@param root string
---@param branch string?
---@return any[]
local function batches(data, root, branch)
  local stored = field(field(field(data, TAKEN), root), branch or "")
  -- Comments and no batch: the one batch kept before a branch kept several.
  if vim.iter(stored):any(valid) and not vim.iter(stored):any(valid_batch) then
    return { { comments = stored } }
  end
  return stored
end

---`batch` as `submitted` lists it, its malformed comments skipped.
---@param batch changeset.SubmittedBatch
---@return changeset.SubmittedBatch
local function as_listed(batch)
  return { comments = vim.deepcopy(vim.tbl_filter(valid, batch.comments)), at = batch.at, to = batch.to }
end

---Whether `stored`, a valid batch as stored, is `batch` as `submitted` listed it: by when and to whom it went, which a
---write moving its comments since leaves alone; by its comments for the one kept before batches recorded either.
---@param stored changeset.SubmittedBatch
---@param batch changeset.SubmittedBatch
---@return boolean
local function same_batch(stored, batch)
  if batch.at then
    return stored.at == batch.at and stored.to == batch.to
  end
  return stored.at == nil and vim.deep_equal(as_listed(stored), batch)
end

---The batches of `stored` that `restore` can bring back, as `submitted` lists them.
---@param stored any[]
---@return changeset.SubmittedBatch[]
local function restorable(stored)
  return vim.iter(stored):filter(valid_batch):map(as_listed):totable()
end

---`batch` ahead of `stored`, the valid batches past 10 forgotten and the malformed ones kept as they are.
---@param batch changeset.SubmittedBatch
---@param stored any[]
---@return any[]
local function ahead(batch, stored)
  local list, count = { batch }, 1
  for _, each in ipairs(stored) do
    if not valid_batch(each) then
      list[#list + 1] = each
    elseif count < KEPT_BATCHES then
      list[#list + 1], count = each, count + 1
    end
  end
  return list
end

---Keeps `list` as the batches `branch` of `root` submitted, removing every key it empties.
---@param data table
---@param root string
---@param branch string?
---@param list any[]
local function set_batches(data, root, branch, list)
  local roots = field(data, TAKEN)
  local branches = field(roots, root)
  branches[branch or ""] = #list > 0 and list or nil
  roots[root] = next(branches) and branches or nil
  data[TAKEN] = next(roots) and roots or nil
end

---Writes the root's list back, removing its key when the list is empty, and tells the subscribers once it lands.
---@param root string
---@param data table
---@param list any[]
---@return boolean written
local function write(root, data, list)
  data[root] = #list > 0 and list or nil
  local written = jsonfile.write(M.path(), data)
  if written then
    for fn in pairs(subscribers) do
      fn()
    end
  end
  return written
end

---Hands the record and the branch checked out at `root` to `change`, then writes the root's list it returns and tells
---the subscribers; writes nothing when it returns none. An unreadable record is never written over, since the
---comments in it can't be derived again.
---@param root string
---@param change fun(data: table, branch: string?): any[]?, any, any
---@return boolean? written nil when the record is unreadable, true when there was nothing to write.
---@return any, any What `change` answered after the list.
local function mutate(root, change)
  local data = jsonfile.read_object(M.path())
  if not data then
    return nil
  end
  local list, a, b = change(data, M.branch(root))
  if not list then
    return true, a, b
  end
  return write(root, data, list), a, b
end

---Rewrites the root's entries without those `drop` matches, adding `add` on the branch checked out and keeping `sent`
---ahead of the batches that branch submitted before, unless nothing would change. An unreadable record is never
---written over, since the comments in it can't be derived again.
---@param root string
---@param drop fun(entry: changeset.ReviewComment): boolean Asked only about valid entries the branch shows; the rest stay.
---@param add changeset.ReviewComment?
---@param sent changeset.SubmittedBatch?
---@return boolean written false when the record is unreadable or the write failed.
---@return boolean changed Whether anything would change.
local function rewrite(root, drop, add, sent)
  local written, changed = mutate(root, function(data, branch)
    local before = entries(root, data)
    local list = vim.tbl_filter(function(entry)
      return not (valid(entry) and on(entry, branch) and drop(entry))
    end, before)
    if sent then
      set_batches(data, root, branch, ahead(sent, batches(data, root, branch)))
    end
    if add then
      table.insert(list, vim.tbl_extend("force", add, { branch = branch }))
    elseif #list == #before and not sent then
      return nil, false
    end
    return list, true
  end)
  return written or false, changed or false
end

---The comments of `root` in `data` that `branch` shows, malformed entries skipped.
---@param data table
---@param root string
---@param branch string?
---@return changeset.ReviewComment[]
local function shown(data, root, branch)
  return vim
    .iter(entries(root, data))
    :filter(function(entry)
      return valid(entry) and on(entry, branch)
    end)
    :map(function(entry)
      return {
        path = entry.path,
        line = entry.line,
        start_line = entry.start_line,
        body = entry.body,
        draft = entry.draft or nil,
      }
    end)
    :totable()
end

---The record as last read, while the file is still that one: `jsonfile.write` renames a new file over it.
---@type { key: string, data: table? }?
local decoded

---The record, for reading only: as `jsonfile.read_object` returns it, decoded again only once the file changes.
---@return table?
local function read_only()
  local file = M.path()
  local stat = vim.uv.fs_stat(file)
  if not stat then
    return jsonfile.read_object(file)
  end
  local key = table.concat({
    file,
    stat.dev,
    stat.ino,
    stat.size,
    stat.mtime.sec,
    stat.mtime.nsec,
    stat.ctime.sec,
    stat.ctime.nsec,
  }, ":")
  if not (decoded and decoded.key == key) then
    decoded = { key = key, data = jsonfile.read_object(file) }
  end
  return decoded.data
end

---Whether the record can be read; a missing one reads as empty.
---@return boolean
function M.readable()
  return read_only() ~= nil
end

---The comments of the repository at `root` that the branch checked out shows, malformed entries skipped; none from
---an unreadable record.
---@param root string As `Paths.root` returns it.
---@return changeset.ReviewComment[]
function M.list(root)
  return shown(read_only() or {}, root, M.branch(root))
end

---What `list` and `submitted` answer, in one read; none from an unreadable record.
---@param root string
---@return changeset.ReviewComment[] listed
---@return changeset.SubmittedBatch[] submitted
---@return string? branch The branch they were read for.
function M.comments(root)
  local data = read_only() or {}
  local branch = M.branch(root)
  return shown(data, root, branch), restorable(batches(data, root, branch)), branch
end

---Replaces the comment at `comment`'s path and range; a blank body drops it instead.
---@param root string
---@param comment changeset.ReviewComment
---@return boolean written false when the record had to change and couldn't be.
function M.keep(root, comment)
  return (
    rewrite(root, function(entry)
      return review_comment.same_range(entry, comment)
    end, vim.trim(comment.body) ~= "" and comment or nil)
  )
end

---Removes the comment at `comment`'s path and range, writing only if one went.
---@param root string
---@param comment changeset.ReviewComment
---@return boolean written False when the record can't be read or written.
---@return boolean dropped Whether a comment went.
function M.drop(root, comment)
  return rewrite(root, function(entry)
    return review_comment.same_range(entry, comment)
  end)
end

---Takes out, in one write, each stored comment equal to one of `batch`'s, body included, so one edited since stays;
---and keeps `batch` for `restore`, ahead of the batches the branch submitted before, the oldest forgotten past 10.
---@param root string
---@param batch changeset.SubmittedBatch
---@return boolean written
function M.take(root, batch)
  return (
    rewrite(root, function(entry)
      return vim.iter(batch.comments):any(function(comment)
        return review_comment.same_range(entry, comment) and entry.body == comment.body
      end)
    end, nil, batch)
  )
end

---The batches the branch checked out submitted, newest first, malformed ones and their malformed comments skipped;
---nil from an unreadable record.
---@param root string
---@return changeset.SubmittedBatch[]?
function M.submitted(root)
  local data = read_only()
  if not data then
    return nil
  end
  return restorable(batches(data, root, M.branch(root)))
end

---Brings back, in one write, `batch` as `submitted` listed it, as saved comments, found by what it is rather than its
---place, which a submit or restore since can shift. One whose range holds a comment now stays in the batch, as the
---store keeps one a range; the batch goes once none does.
---@param root string
---@param batch changeset.SubmittedBatch
---@return integer? restored nil when the record is unreadable or the write failed.
---@return integer kept Still submitted, for a restore once their ranges are free; with `restored`, 0 for a batch the
---branch checked out no longer holds.
function M.restore(root, batch)
  local written, restored, still = mutate(root, function(data, branch)
    local stored = batches(data, root, branch)
    local index = vim.iter(ipairs(stored)):find(function(_, each)
      return valid_batch(each) and same_batch(each, batch)
    end)
    if not index then
      return nil, 0, 0
    end
    local found = stored[index]
    local list = entries(root, data)
    local back, kept = {}, {}
    for _, comment in ipairs(vim.tbl_filter(valid, found.comments)) do
      local held = vim.iter(list):any(function(entry)
        return valid(entry) and on(entry, branch) and review_comment.same_range(entry, comment)
      end)
      table.insert(held and kept or back, comment)
    end
    for _, comment in ipairs(back) do
      list[#list + 1] = {
        path = comment.path,
        line = comment.line,
        start_line = comment.start_line,
        body = comment.body,
        branch = branch,
      }
    end
    found.comments = kept
    if #kept == 0 then
      table.remove(stored, index)
    end
    set_batches(data, root, branch, stored)
    return list, #back, #kept
  end)
  if not written then
    return nil, 0
  end
  return restored, still
end

---@class changeset.ReviewCommentMerge
---@field comment changeset.StoredReviewComment The comment the others merged into, as it ends up.
---@field count integer How many comments it holds now.

---A copy of `entry`, on the lines of the move made from it, filed under `branch` when it has none, as `keep` files it.
---@param entry changeset.StoredReviewComment
---@param moves changeset.ReviewCommentMove[]
---@param branch string?
---@return changeset.StoredReviewComment
local function moved(entry, moves, branch)
  local copy = vim.deepcopy(entry)
  local move = vim.iter(moves):find(function(each)
    return review_comment.same_range(entry, each.from)
      and entry.body == each.from.body
      and (entry.draft or nil) == each.from.draft
  end)
  if move then
    copy.line, copy.start_line, copy.branch = move.to.line, move.to.start_line, entry.branch or branch
  end
  return copy
end

---`stored` with each the branch shows on the lines of the move made from it. Comments that end up on one range merge
---into the first listed, their bodies a blank line apart, a draft when any was, so the store keeps one a range.
---@param stored any[] As stored, malformed ones included, which stay as they are.
---@param moves changeset.ReviewCommentMove[]
---@param branch string?
---@return any[] entries
---@return changeset.ReviewCommentMerge[] merged
function M._relocate(stored, moves, branch)
  local list, on_range, merged = {}, {}, {}
  for _, entry in ipairs(stored) do
    if valid(entry) and on(entry, branch) then
      entry = moved(entry, moves, branch)
      local key = ("%s:%s:%s"):format(entry.path, entry.start_line, entry.line)
      local into = on_range[key]
      if into then
        local comment = into.comment
        comment.body, comment.draft = comment.body .. "\n\n" .. entry.body, comment.draft or entry.draft
        comment.branch = comment.branch or branch
        into.count = into.count + 1
        if into.count == 2 then
          merged[#merged + 1] = into
        end
      else
        on_range[key], list[#list + 1] = { comment = entry, count = 1 }, entry
      end
    else
      list[#list + 1] = entry
    end
  end
  return list, merged
end

---Puts each stored comment equal to a move's `from` on its `to`'s lines, in one write, merging those that end up on
---one range: those listed, and those of each batch the branch submitted.
---@param root string
---@param moves changeset.ReviewCommentMove[]
---@return boolean written
---@return changeset.ReviewCommentMerge[] merged Of those listed only.
function M.move(root, moves)
  local written, merged = mutate(root, function(data, branch)
    local list, found = M._relocate(entries(root, data), moves, branch)
    local stored = batches(data, root, branch)
    for _, batch in ipairs(stored) do
      if valid_batch(batch) then
        -- No branch: the batch is filed under one, not its comments.
        batch.comments = (M._relocate(batch.comments, moves, nil))
      end
    end
    set_batches(data, root, branch, stored)
    return list, found
  end)
  return written or false, merged or {}
end

---Removes every comment of the repository at `root` that the branch checked out shows, leaving the batches it
---submitted.
---@param root string
---@return boolean written
function M.drop_all(root)
  return (rewrite(root, function()
    return true
  end))
end

---Calls `fn` after each write. Subscribing again does nothing.
---@param fn fun()
function M.subscribe(fn)
  subscribers[fn] = true
end

return M
