---Marks each review comment kept on this machine in its file's buffer, at its line or range, in every loaded buffer
---of a repository that has comments, and answers hover on those lines.
local Paths = require("changeset.paths")
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

---Each buffer's marks, by extmark id, and the stored comment each marks.
---@type table<integer, table<integer, changeset.ReviewComment>>
local placed = {}

---Marks `comment` in `buf`, answering the mark's id.
---@param buf integer
---@param comment changeset.ReviewComment
---@return integer
local function mark(buf, comment)
  local row = (comment.start_line or comment.line) - 1
  local bubble, hl = M.glyph(comment)
  local circle = comment.draft and render.REVIEW_COMMENT_DRAFT_CIRCLE or render.REVIEW_COMMENT_CIRCLE
  local id = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
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
  return id
end

---Each comment marked in `buf` whose mark edits have moved, with the lines the mark covers now.
---@param buf integer
---@return changeset.ReviewCommentMove[]
local function moves(buf)
  local found = {}
  for id, comment in pairs(placed[buf] or {}) do
    local at = vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, { details = true })
    local first, last = at[1] and at[1] + 1, at[3] and at[3].end_row + 1
    if first and (first ~= (comment.start_line or comment.line) or last ~= comment.line) then
      local to = vim.deepcopy(comment)
      to.line, to.start_line = last, first < last and first or nil
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

---Markdown for each review comment whose lines cover line `lnum` of `fname`; nil when none does.
---@param fname string
---@param lnum integer
---@return string?
local function hover_text(fname, lnum)
  local buf = vim.fn.bufnr(fname)
  if buf == -1 then
    return
  end
  local root = Paths.root(buf)
  local path = vim.fs.relpath(root, vim.fs.normalize(fname))
  if not path then
    return
  end
  local entries = {}
  for _, comment in ipairs(comment_store.list(root)) do
    local first, last = comment.start_line or comment.line, comment.line
    if comment.path == path and last and first <= lnum and lnum <= last then
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

---`comment` on the lines `moved` has it on, else as it is.
---@param comment changeset.ReviewComment
---@param moved changeset.ReviewCommentMove[]
---@return changeset.ReviewComment
local function moved_to(comment, moved)
  local move = vim.iter(moved):find(function(each)
    return vim.deep_equal(each.from, comment)
  end)
  return move and move.to or comment
end

---Marks `comments` that belong to `buf`'s file, a moved one on the lines `moved` has it on, answering whether it
---marked anything.
---@param buf integer
---@param root string
---@param comments changeset.ReviewComment[]
---@param moved changeset.ReviewCommentMove[]
---@return boolean
local function mark_file(buf, root, comments, moved)
  local name = vim.api.nvim_buf_get_name(buf)
  local path = name ~= "" and vim.fs.relpath(root, vim.fs.normalize(name))
  if not path then
    return false
  end
  local line_count = vim.api.nvim_buf_line_count(buf)
  local marked = {}
  for _, comment in ipairs(comments) do
    local shown = comment.path == path and comment.line and moved_to(comment, moved)
    if shown and shown.line <= line_count then
      placed[buf][mark(buf, shown)] = comment
      marked[#marked + 1] = shown
    end
  end
  review_comment_blocks.draw(buf, marked)
  return #marked > 0
end

---Redraws `buf`'s marks from `by_root`, the store's comments by repository, read once a pass.
---@param buf integer
---@param by_root table<string, changeset.ReviewComment[]>
local function draw(buf, by_root)
  -- Drawn from the stored lines, a modified buffer's marks would lose where its edits moved them before the write
  -- that stores it.
  local moved = vim.bo[buf].modified and moves(buf) or {}
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, sign_ns, 0, -1)
  placed[buf] = {}
  review_comment_blocks.draw(buf, {})
  local root = Paths.root(buf)
  by_root[root] = by_root[root] or comment_store.list(root)
  if mark_file(buf, root, by_root[root], moved) then
    attach_hover(buf, root)
  else
    hover.detach(buf)
  end
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

-- Fires: a buffer written. Its marks moved with the edits, so storing where they stand keeps each comment on the
-- code it was written about.
vim.api.nvim_create_autocmd("BufWritePost", {
  group = "changeset.review_comments",
  desc = "changeset: store the lines a written file's review comment marks moved to",
  callback = function(args)
    -- Written to another file: its own still holds the stored lines.
    if vim.bo[args.buf].modified then
      return
    end
    local moved = moves(args.buf)
    if #moved == 0 then
      return draw(args.buf, {})
    end
    if not comment_store.move(Paths.root(args.buf), moved) then
      vim.notify("Changeset: can't move the review comments in " .. comment_store.path(), vim.log.levels.WARN)
      draw(args.buf, {})
    end
  end,
})

-- Fires: Neovim regaining focus, which a branch switched outside it comes back with. Comments belong to the branch
-- they were written on.
vim.api.nvim_create_autocmd("FocusGained", {
  group = "changeset.review_comments",
  desc = "changeset: mark the review comments of the branch checked out",
  callback = function()
    M.redraw()
  end,
})

-- Fires: gitsigns seeing HEAD move, a checkout made anywhere, which it publishes without a buffer.
vim.api.nvim_create_autocmd("User", {
  pattern = "GitSignsUpdate",
  group = "changeset.review_comments",
  desc = "changeset: mark the review comments of the branch checked out",
  callback = function(args)
    if not (args.data and args.data.buffer) then
      M.redraw()
    end
  end,
})

M.redraw()

return M
