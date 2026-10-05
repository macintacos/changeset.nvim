---Marks each review comment of the tree's pending review, and each draft of its PR, in its file's buffer, at its line or range.
local build = require("changeset.build")
local config = require("changeset.config")
local drafts = require("changeset.drafts")
local pending_state = require("changeset.pending_state")
local render = require("changeset.render")

local M = {}

local ns = vim.api.nvim_create_namespace("changeset.review_comments")

-- Holds only the bubbles, so `M.bubble` finds a line's without sorting out the rest.
local sign_ns = vim.api.nvim_create_namespace("changeset.review_comment_signs")

-- ponytail: lines are the PR head's, so where the file on disk differs from the head (unpushed commits, saved uncommitted edits) marks and delete land off by the lines moved above; hide marks in such a file if that bites.
-- ponytail: a LEFT-side review comment (on a deleted line) spans its number in the new file; skip LEFT once it is recorded.
---@class changeset.Spanned
---@field path string
---@field line integer?
---@field start_line integer?
---@field body string

---The lines `comment` spans in its file; nil when it has none: outdated or file-level.
---@param comment changeset.Spanned
---@return integer? first
---@return integer? last
local function span(comment)
  if comment.line then
    return comment.start_line or comment.line, comment.line
  end
end

---The narrowest review comment or draft of `path` whose marks light line `lnum`; ties go to the first listed.
---@generic T : changeset.Spanned
---@param comments T[]
---@param path string
---@param lnum integer
---@return T?
function M.at(comments, path, lnum)
  local narrowest, narrowest_width
  for _, comment in ipairs(comments) do
    local first, last = span(comment)
    if
      comment.path == path
      and first
      and first <= lnum
      and lnum <= last
      and not (narrowest_width and last - first >= narrowest_width)
    then
      narrowest, narrowest_width = comment, last - first
    end
  end
  return narrowest
end

---@class changeset.review_comments.Look
---@field circle string Leads the body at the end of the first line.
---@field bubble string Marks the first line, in its sign column unless `review_comment.sign` is false.
---@field hl string

---@type changeset.review_comments.Look
local SAVED = { circle = "● ", bubble = "󰍩", hl = render.REVIEW_COMMENT_HL }

---@type changeset.review_comments.Look
local DRAFT = { circle = "○ ", bubble = "󰍪", hl = render.REVIEW_DRAFT_HL }

---@type table<string, string>
local BUBBLE_BY_HL = { [SAVED.hl] = SAVED.bubble, [DRAFT.hl] = DRAFT.bubble }

---@param buf integer
---@param spanned changeset.Spanned
---@param look changeset.review_comments.Look
local function mark(buf, spanned, look)
  local first, last = span(spanned)
  local row = first - 1
  vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
    end_row = last - 1,
    number_hl_group = look.hl,
    virt_text = {
      { look.circle, look.hl },
      { spanned.body:match("^[^\r\n]*"), render.REVIEW_COMMENT_BODY_HL },
    },
  })
  -- The first bubble on a line stays: review comments are drawn before drafts.
  if #vim.api.nvim_buf_get_extmarks(buf, sign_ns, { row, 0 }, { row, 0 }, { limit = 1 }) == 0 then
    -- The default priority, 4096, draws it over gitsigns' and diagnostics' signs. Without
    -- `sign_text` the mark takes no cell but keeps its group, which `M.bubble` answers from.
    vim.api.nvim_buf_set_extmark(buf, sign_ns, row, 0, {
      sign_text = config.get().review_comment.sign and look.bubble or nil,
      sign_hl_group = look.hl,
    })
  end
end

---The bubble on line `lnum` of `buf` and its group, from the marks already drawn; nil on a line without one.
---@param buf integer
---@param lnum integer 1-based.
---@return string? glyph
---@return string? hl
function M.bubble(buf, lnum)
  local found = vim.api.nvim_buf_get_extmarks(buf, sign_ns, { lnum - 1, 0 }, { lnum - 1, -1 }, { details = true })[1]
  local hl = found and found[4].sign_hl_group
  if hl then
    return BUBBLE_BY_HL[hl], hl
  end
end

---@class changeset.review_comments.Marks
---@field root string
---@field comments changeset.ReviewComment[]
---@field drafts changeset.Draft[]

---What a redraw marks, read once for every buffer it draws.
---@return changeset.review_comments.Marks?
local function current_marks()
  local tree = build.current()
  local found = tree and tree.pr and pending_state.get(tree.root, tree.pr)
  if tree and found then
    return {
      root = tree.root,
      comments = found.review and found.review.comments or {},
      drafts = drafts.list(found.pr),
    }
  end
end

---@param buf integer
---@param marks changeset.review_comments.Marks?
local function draw(buf, marks)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, sign_ns, 0, -1)
  local name = vim.api.nvim_buf_get_name(buf)
  if not marks or name == "" then
    return
  end
  local path = vim.fs.relpath(marks.root, vim.fs.normalize(name))
  local line_count = vim.api.nvim_buf_line_count(buf)
  ---@param spanned changeset.Spanned
  ---@return boolean
  local function fits(spanned)
    local first, last = span(spanned)
    return path ~= nil and spanned.path == path and first ~= nil and last <= line_count
  end
  for _, comment in ipairs(marks.comments) do
    if fits(comment) then
      mark(buf, comment, SAVED)
    end
  end
  for _, draft in ipairs(marks.drafts) do
    if fits(draft) then
      mark(buf, draft, DRAFT)
    end
  end
end

local function draw_loaded()
  local marks = current_marks()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      draw(buf, marks)
    end
  end
end

-- `require("changeset").rows()` builds a tree without the sidebar defining the groups.
render.define_highlights()

-- Fires: GitHub's answer on the pending review being kept, so the marks follow it.
pending_state.subscribe(draw_loaded)

-- Fires: a draft kept or dropped, so its mark follows it without asking GitHub.
drafts.subscribe(draw_loaded)

-- Fires: every tree event, so a tree on another PR, or on none, drops the old PR's marks before GitHub answers.
build.subscribe(draw_loaded)

-- Fires: a file read into a buffer, which starts with none of the marks.
vim.api.nvim_create_autocmd("BufReadPost", {
  group = vim.api.nvim_create_augroup("changeset.review_comments", { clear = true }),
  desc = "changeset: mark the kept pending review's review comments and the PR's drafts in a file as it is read",
  callback = function(args)
    draw(args.buf, current_marks())
  end,
})

return M
