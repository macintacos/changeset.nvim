---Marks each review comment of the tree's pending review in its file's buffer, at its line or range.
local build = require("changeset.build")
local pending_state = require("changeset.pending_state")
local render = require("changeset.render")

local NS = vim.api.nvim_create_namespace("changeset.review_comments")

-- ponytail: marks sit at the pushed head's line numbers, so unpushed commits that move lines shift them; hide marks in a file that differs from the head if that bites.
-- ponytail: a LEFT-side review comment (on a deleted line) draws at its number in the new file; skip LEFT once it is recorded.

---@param buf integer
local function draw(buf)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  local tree = build.current()
  local found = tree and tree.pr and pending_state.get(tree.root, tree.pr)
  local name = vim.api.nvim_buf_get_name(buf)
  if not (tree and found and found.review) or name == "" then
    return
  end
  local path = vim.fs.relpath(tree.root, vim.fs.normalize(name))
  local last = vim.api.nvim_buf_line_count(buf)
  for _, comment in ipairs(found.review.comments) do
    if path and comment.path == path and comment.line and comment.line <= last then
      vim.api.nvim_buf_set_extmark(buf, NS, (comment.start_line or comment.line) - 1, 0, {
        end_row = comment.line - 1,
        number_hl_group = render.REVIEW_COMMENT_HL,
        virt_text = {
          { "● ", render.REVIEW_COMMENT_HL },
          { vim.split(comment.body, "\n")[1], render.REVIEW_COMMENT_BODY_HL },
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

-- Fires: GitHub's answer on the pending review being kept, after a `:Changeset pr` verb or focus.
pending_state.subscribe(draw_loaded)

-- Fires: the tree reading its diff or symbols, or landing on another branch or PR.
build.subscribe(draw_loaded)

vim.api.nvim_create_autocmd("BufReadPost", {
  group = vim.api.nvim_create_augroup("changeset.review_comments", {}),
  desc = "Fires: a file read into a buffer, so it shows the kept answer's review comments",
  callback = function(args)
    draw(args.buf)
  end,
})
