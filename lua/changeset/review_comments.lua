---Marks each review comment kept on this machine in its file's buffer, at its line or range, in every loaded buffer
---of a repository that has comments, and answers hover on those lines.
local Paths = require("changeset.paths")
local buffers = require("changeset.buffers")
local comment_store = require("changeset.comment_store")
local config = require("changeset.config")
local hover = require("changeset.hover")
local review_comment_blocks = require("changeset.review_comment_blocks")
local render = require("changeset.render")

local M = {}

local ns = vim.api.nvim_create_namespace("changeset.review_comments")

-- Holds only the bubbles, so `M.bubble` finds a line's without sorting out the rest.
local sign_ns = vim.api.nvim_create_namespace("changeset.review_comment_signs")

---The narrowest review comment of `path` whose marks light line `lnum`; ties go to the first listed.
---@param comments changeset.ReviewComment[]
---@param path string
---@param lnum integer
---@return changeset.ReviewComment?
function M.at(comments, path, lnum)
  local narrowest, narrowest_width
  for _, comment in ipairs(comments) do
    local first, last = comment.start_line or comment.line, comment.line
    if
      comment.path == path
      and last
      and first <= lnum
      and lnum <= last
      and not (narrowest_width and last - first >= narrowest_width)
    then
      narrowest, narrowest_width = comment, last - first
    end
  end
  return narrowest
end

local BUBBLE = "󰍩"
-- The outline of the saved bubble: the same note, not yet filled in.
local DRAFT_BUBBLE = "󰍪"

---`comment`'s bubble, the outline for a draft, and its group.
---@param comment changeset.ReviewComment
---@return string glyph
---@return string hl
function M.glyph(comment)
  return comment.draft and DRAFT_BUBBLE or BUBBLE, render.review_comment_hl(comment)
end

---Each buffer's lines as they stood when its line comments were last drawn with it unmodified, which is where the
---stored lines sit.
---@type table<integer, string[]>
local snapshots = {}

---The changedtick each snapshot was taken at: a buffer still at it holds the same lines, so a redraw needn't copy them.
---@type table<integer, integer>
local snapshot_ticks = {}

---The branch each buffer's marks were last drawn for.
---@type table<integer, string>
local drawn_for = {}

---Marks `comment` in `buf`.
---@param buf integer
---@param comment changeset.ReviewComment
local function mark(buf, comment)
  local row = (comment.start_line or comment.line) - 1
  local bubble, hl = M.glyph(comment)
  local circle = comment.draft and render.REVIEW_COMMENT_DRAFT_CIRCLE or render.REVIEW_COMMENT_CIRCLE
  vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
    end_row = comment.line - 1,
    -- A line added right above the last moves the end down with the last, rather than onto the new line.
    end_right_gravity = true,
    number_hl_group = hl,
    -- A block already holds the whole text.
    virt_text = not review_comment_blocks.shown() and {
      { circle .. " ", hl },
      { comment.body:match("^[^\r\n]*"), render.REVIEW_COMMENT_BODY_HL },
    } or nil,
  })
  local existing = vim.api.nvim_buf_get_extmarks(buf, sign_ns, { row, 0 }, { row, 0 }, { limit = 1, details = true })[1]
  -- One bubble a line, and a draft's wins it: unfinished work is what should stand out.
  if not existing or (comment.draft and existing[4].sign_hl_group ~= render.REVIEW_COMMENT_DRAFT_HL) then
    -- The default priority, 4096, draws it over gitsigns' and diagnostics' signs. Without
    -- `sign_text` the mark takes no cell but keeps its group, which `M.bubble` answers from.
    vim.api.nvim_buf_set_extmark(buf, sign_ns, row, 0, {
      id = existing and existing[1],
      sign_text = config.get().review_comment.sign and bubble or nil,
      sign_hl_group = hl,
    })
  end
end

---Where line `lnum` stands after the changes `hunks`, `vim.text.diff` indices, made: as a range's first line and as
---its last. They differ only for a deleted line, the first going to the line after the deletion, the last to the one
---before it. A line in a rewritten block keeps its place in the block, as far as the new block reaches.
---@param hunks integer[][]
---@param lnum integer
---@return integer first
---@return integer last
local function map_line(hunks, lnum)
  local shift = 0
  for _, hunk in ipairs(hunks) do
    local old_start, old_count, new_start, new_count = unpack(hunk)
    -- An insertion's start is the line it follows.
    if lnum < old_start or old_count == 0 and lnum == old_start then
      break
    end
    if lnum < old_start + old_count then
      if new_count == 0 then
        return new_start + 1, new_start
      end
      local line = new_start + math.min(lnum - old_start, new_count - 1)
      return line, line
    end
    shift = shift + new_count - old_count
  end
  return lnum + shift, lnum + shift
end

---`comment`, a line comment, on the lines `hunks` moved its own to, within `line_count`; nil when they stayed. A
---comment whose lines were all deleted goes to the line after them.
---@param comment changeset.ReviewComment
---@param hunks integer[][]
---@param line_count integer
---@return changeset.ReviewComment?
local function moved(comment, hunks, line_count)
  local line = comment.line --[[@as integer]]
  local first = map_line(hunks, comment.start_line or line)
  local _, last = map_line(hunks, line)
  last = math.min(math.max(first, last), line_count)
  first = math.min(first, line_count)
  if first == (comment.start_line or line) and last == line then
    return nil
  end
  local to = vim.deepcopy(comment)
  to.line, to.start_line = last, first < last and first or nil
  return to
end

---`lines` as one text, each line ended, as `vim.text.diff` takes it.
---@param lines string[]
---@return string
local function text(lines)
  return table.concat(lines, "\n") .. "\n"
end

---Each of `comments`, line comments of `buf`'s file, that the edits made since its snapshot moved, with the lines
---they moved to; none without a snapshot.
---@param buf integer
---@param comments changeset.ReviewComment[]
---@return changeset.ReviewCommentMove[]
local function moves(buf, comments)
  local snapshot = snapshots[buf]
  if not snapshot then
    return {}
  end
  local now = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local hunks = vim.text.diff(text(snapshot), text(now), { result_type = "indices", algorithm = "histogram" })
  ---@cast hunks integer[][]
  local found = {}
  for _, comment in ipairs(comments) do
    local to = moved(comment, hunks, #now)
    if to then
      found[#found + 1] = { from = comment, to = to }
    end
  end
  return found
end

---The bubble on line `lnum` of `buf` and its group, from the marks already drawn; nil on a line without one.
---@param buf integer
---@param lnum integer 1-based.
---@return string? glyph
---@return string? hl
function M.bubble(buf, lnum)
  local found = vim.api.nvim_buf_get_extmarks(
    buf,
    sign_ns,
    { lnum - 1, 0 },
    { lnum - 1, -1 },
    { limit = 1, details = true }
  )
  if found[1] then
    local hl = found[1][4].sign_hl_group
    return hl == render.REVIEW_COMMENT_DRAFT_HL and DRAFT_BUBBLE or BUBBLE, hl
  end
end

---"line 4", "lines 3-5" for a range, or "whole file" for none.
---@param first integer?
---@param last integer?
---@return string
function M.lines_label(first, last)
  if not (first and last) then
    return "whole file"
  end
  return first < last and ("lines %d-%d"):format(first, last) or ("line %d"):format(last)
end

---The comments of `comments` on lines of `buf`'s file.
---@param buf integer
---@param root string
---@param comments changeset.ReviewComment[]
---@return changeset.ReviewComment[]
local function on_lines(buf, root, comments)
  local name = vim.api.nvim_buf_get_name(buf)
  local path = name ~= "" and vim.fs.relpath(root, vim.fs.normalize(name))
  return vim.tbl_filter(function(comment)
    return comment.path == path and comment.line ~= nil
  end, path and comments or {})
end

---`comments` where `buf`'s edits since its snapshot moved them.
---@param buf integer
---@param comments changeset.ReviewComment[]
---@return changeset.ReviewComment[]
local function where_edited(buf, comments)
  local to = {}
  for _, move in ipairs(moves(buf, comments)) do
    to[move.from] = move.to
  end
  return vim.tbl_map(function(comment)
    return to[comment] or comment
  end, comments)
end

---Markdown for each review comment whose lines, where its marks are drawn, cover line `lnum` of `fname`; nil when
---none does.
---@param fname string
---@param lnum integer
---@return string?
local function hover_text(fname, lnum)
  local buf = buffers.loaded(fname)
  if not buf then
    return
  end
  local root = Paths.root(buf)
  local comments = on_lines(buf, root, comment_store.list(root))
  if vim.bo[buf].modified then
    comments = where_edited(buf, comments)
  end
  local entries = {}
  for _, comment in ipairs(comments) do
    local first, last = comment.start_line or comment.line, comment.line
    if first <= lnum and lnum <= last then
      local body = comment.body:gsub("\r\n", "\n")
      local heading = comment.draft and "Draft review comment" or "Review comment"
      table.insert(entries, ("**%s · %s**\n\n%s"):format(heading, M.lines_label(first, last), body))
    end
  end
  if #entries > 0 then
    return table.concat(entries, "\n\n---\n\n")
  end
end

local attach_hover = hover.serve(hover_text)

---Marks `comments`, line comments of `buf`'s file, answering whether it marked any.
---@param buf integer
---@param comments changeset.ReviewComment[]
---@return boolean
local function mark_file(buf, comments)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local marked = vim.tbl_filter(function(comment)
    return comment.line <= line_count
  end, comments)
  for _, comment in ipairs(marked) do
    mark(buf, comment)
  end
  review_comment_blocks.draw(buf, marked)
  return #marked > 0
end

---A repository's comments, as a pass reads them once.
---@class changeset.RepositoryComments
---@field listed changeset.ReviewComment[]
---@field sent changeset.ReviewComment[] Those of every batch the branch submitted: no mark shows them, but edits move them.

---`root`'s comments, read into `by_root` on a pass's first ask.
---@param by_root table<string, changeset.RepositoryComments>
---@param root string
---@return changeset.RepositoryComments
local function read(by_root, root)
  if not by_root[root] then
    local listed, submitted = comment_store.comments(root)
    local sent = vim.iter(submitted):map(function(batch)
      return batch.comments
    end)
    by_root[root] = { listed = listed, sent = sent:flatten():totable() }
  end
  return by_root[root]
end

---Redraws `buf`'s marks from `by_root`, the store's comments by repository, read once a pass.
---@param buf integer
---@param by_root table<string, changeset.RepositoryComments>
local function draw(buf, by_root)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, sign_ns, 0, -1)
  review_comment_blocks.draw(buf, {})
  local root = Paths.root(buf)
  local stored = read(by_root, root)
  drawn_for[buf] = comment_store.branch(root)
  local comments = on_lines(buf, root, stored.listed)
  if vim.bo[buf].modified then
    -- On the stored lines, a modified buffer's marks would leave the code its edits moved.
    comments = where_edited(buf, comments)
  else
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    if not (#comments > 0 or #on_lines(buf, root, stored.sent) > 0) then
      snapshots[buf], snapshot_ticks[buf] = nil, nil
    elseif snapshot_ticks[buf] ~= tick then
      snapshots[buf], snapshot_ticks[buf] = vim.api.nvim_buf_get_lines(buf, 0, -1, false), tick
    end
  end
  if mark_file(buf, comments) then
    attach_hover(buf, root)
  else
    hover.detach(buf)
  end
end

---Warns of each comment others merged into, which no write should do quietly: it can't be split again.
---@param merged changeset.ReviewCommentMerge[]
local function warn_merged(merged)
  for _, merge in ipairs(merged) do
    local comment = merge.comment
    vim.notify(
      ("Changeset: merged %d review comments on %s of %s%s"):format(
        merge.count,
        M.lines_label(comment.start_line or comment.line, comment.line),
        comment.path,
        comment.draft and " into a draft" or ""
      ),
      vim.log.levels.WARN
    )
  end
end

---Stores the lines the edits written to `buf`'s file moved its comments to.
---@param buf integer
local function store_moves(buf)
  local root = Paths.root(buf)
  local by_root = {}
  local stored = read(by_root, root)
  local found = moves(buf, vim.list_extend(on_lines(buf, root, stored.listed), on_lines(buf, root, stored.sent)))
  if #found == 0 then
    return draw(buf, by_root)
  end
  local written, merged = comment_store.move(root, found)
  if not written then
    vim.notify("Changeset: can't move the review comments in " .. comment_store.path(), vim.log.levels.WARN)
    return draw(buf, {})
  end
  warn_merged(merged)
end

---Redraws every loaded buffer's marks from the store.
function M.redraw()
  local by_root = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      draw(buf, by_root)
    end
  end
end

---Redraws the marks of each loaded buffer whose repository has checked out another branch since they were drawn.
local function redraw_switched()
  local by_root = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and comment_store.branch(Paths.root(buf)) ~= drawn_for[buf] then
      draw(buf, by_root)
    end
  end
end

render.define_highlights()

-- The meta highlight is mixed from Comment's foreground, which a new colorscheme replaces. Here rather than in
-- the sidebar's module, since a review verb loads this one without it.
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("changeset.highlights", { clear = true }),
  desc = "changeset: rebuild the highlight groups against the new palette",
  callback = render.define_highlights,
})

-- Fires: a review comment kept, dropped or cleared, so its marks follow it.
comment_store.subscribe(M.redraw)

-- Fires: a file read into a buffer, which starts with none of the marks.
vim.api.nvim_create_autocmd("BufReadPost", {
  group = vim.api.nvim_create_augroup("changeset.review_comments", { clear = true }),
  desc = "changeset: mark the review comments kept for a file as it is read",
  callback = function(args)
    draw(args.buf, {})
  end,
})

-- Fires: a buffer written. Storing the lines its edits moved each comment to keeps the comment on the code it was
-- written about.
vim.api.nvim_create_autocmd("BufWritePost", {
  group = "changeset.review_comments",
  desc = "changeset: store the lines a written file's edits moved its review comments to",
  callback = function(args)
    -- Written to another file: its own still holds the stored lines.
    if not vim.bo[args.buf].modified then
      store_moves(args.buf)
    end
  end,
})

-- Fires: a buffer unloaded, whose lines and branch are read again with it.
vim.api.nvim_create_autocmd("BufUnload", {
  group = "changeset.review_comments",
  desc = "changeset: forget what an unloaded buffer's review comments were drawn from",
  callback = function(args)
    snapshots[args.buf], snapshot_ticks[args.buf], drawn_for[args.buf] = nil, nil, nil
  end,
})

-- Fires: Neovim regaining focus, which a branch switched outside it comes back with. Comments belong to the branch
-- they were written on. Only a switched branch redraws, since a redraw lets go of a parked block, and focus comes
-- back from every trip to the agent's pane.
vim.api.nvim_create_autocmd("FocusGained", {
  group = "changeset.review_comments",
  desc = "changeset: mark the review comments of a branch checked out since they were drawn",
  callback = redraw_switched,
})

-- Fires: gitsigns publishing a change without a buffer, which it does when HEAD moves and on every `:cd`.
vim.api.nvim_create_autocmd("User", {
  pattern = "GitSignsUpdate",
  group = "changeset.review_comments",
  desc = "changeset: mark the review comments of a branch checked out since they were drawn",
  callback = function(args)
    -- One buffer's update comes as it is typed in.
    if not (args.data and args.data.buffer) then
      redraw_switched()
    end
  end,
})

M.redraw()

return M
