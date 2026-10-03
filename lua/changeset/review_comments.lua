---Marks each review comment of the tree's pending review in its file's buffer, at its line or range.
local build = require("changeset.build")
local pending_state = require("changeset.pending_state")
local render = require("changeset.render")

local M = {}

local ns = vim.api.nvim_create_namespace("changeset.review_comments")

-- ponytail: lines are the PR head's, so where the file on disk differs from the head (unpushed commits, saved uncommitted edits) marks and delete land off by the lines moved above; hide marks in such a file if that bites.
-- ponytail: a LEFT-side review comment (on a deleted line) spans its number in the new file; skip LEFT once it is recorded.
---The lines `comment` spans in its file; nil when it has none: outdated or file-level.
---@param comment changeset.ReviewComment
---@return integer? first
---@return integer? last
local function span(comment)
  if comment.line then
    return comment.start_line or comment.line, comment.line
  end
end

---The narrowest review comment of `path` whose marks light line `lnum`; ties go to the first listed.
---@param comments changeset.ReviewComment[]
---@param path string
---@param lnum integer
---@return changeset.ReviewComment?
function M.at(comments, path, lnum)
  local best, width
  for _, comment in ipairs(comments) do
    local first, last = span(comment)
    if comment.path == path and first and first <= lnum and lnum <= last and not (width and last - first >= width) then
      best, width = comment, last - first
    end
  end
  return best
end

---@param buf integer
local function draw(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local tree = build.current()
  local found = tree and tree.pr and pending_state.get(tree.root, tree.pr)
  local name = vim.api.nvim_buf_get_name(buf)
  if not (tree and found and found.review) or name == "" then
    return
  end
  local path = vim.fs.relpath(tree.root, vim.fs.normalize(name))
  local line_count = vim.api.nvim_buf_line_count(buf)
  for _, comment in ipairs(found.review.comments) do
    local first, last = span(comment)
    if path and comment.path == path and first and last <= line_count then
      vim.api.nvim_buf_set_extmark(buf, ns, first - 1, 0, {
        end_row = last - 1,
        number_hl_group = render.REVIEW_COMMENT_HL,
        virt_text = {
          { "● ", render.REVIEW_COMMENT_HL },
          { comment.body:match("^[^\r\n]*"), render.REVIEW_COMMENT_BODY_HL },
        },
      })
    end
  end
end

local function draw_loaded()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      draw(buf)
    end
  end
end

-- `require("changeset").rows()` builds a tree without the sidebar defining the groups.
render.define_highlights()

-- Fires: GitHub's answer on the pending review being kept, so the marks follow it.
pending_state.subscribe(draw_loaded)

-- Fires: every tree event, so a tree on another PR, or on none, drops the old PR's marks before GitHub answers.
build.subscribe(draw_loaded)

-- Fires: a file read into a buffer, which starts with none of the marks.
vim.api.nvim_create_autocmd("BufReadPost", {
  group = vim.api.nvim_create_augroup("changeset.review_comments", { clear = true }),
  desc = "changeset: mark the kept pending review's review comments in a file as it is read",
  callback = function(args)
    draw(args.buf)
  end,
})

return M
