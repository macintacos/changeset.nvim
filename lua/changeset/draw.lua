---Puts the tree on the sidebar's buffer, through the pure `render`: lines, marks, header and row states.
---The sidebar state's View decides what is on each line; `band_for` builds a row's preview band.

local icons = require("changeset.icons")
local render = require("changeset.render")
local Rows = require("changeset.rows")
local sidebar_state = require("changeset.sidebar_state")
local view = require("changeset.view")
local window = require("changeset.window")

-- The totals row over the tree and the blank one under it.
local HEADER_LINES = 2

local M = {}

local ns = vim.api.nvim_create_namespace("changeset")
-- Separate from `ns` so the tracker can repaint row backgrounds without redrawing the tree.
local rows_ns = vim.api.nvim_create_namespace("changeset.rows")

---@param row changeset.Row
---@return string glyph, string hl
local function icon_for(row)
  if row.kind == "section" then
    return icons.get("directory", row.icon)
  end
  if row.kind == "file" then
    return icons.get("file", row.path)
  end
  return icons.get("lsp", row.kind == "symbol" and row.symbol_kind or "Text")
end

---The row under the sidebar's cursor.
---@return changeset.Row?
function M.row_at_cursor()
  local state = sidebar_state.current()
  if not state then
    return nil
  end
  local win = window.win()
  if not win then
    return nil
  end
  return state.view:row(vim.api.nvim_win_get_cursor(win)[1])
end

---The preview band's contents for `row`.
---@param row changeset.Row
---@param jump (string|false)? The jump key the sidebar bound.
---@return changeset.Band
function M.band_for(row, jump)
  local glyph, hl = icons.get("file", row.path)
  return {
    icon = glyph,
    icon_hl = render.band_icon(hl),
    path = row.path,
    -- Only a symbol row names its destination. An orphan hunk's own text is the
    -- changed line, which is not a place and does not read as one.
    destination = row.kind == "symbol" and row.name or nil,
    jump = jump,
  }
end

---The sidebar as drawn, for `changeset.position`; errors before the first build.
---@return changeset.position.View
function M.view()
  local state = sidebar_state.current()
  assert(state, "changeset: no tree built yet")
  local win = window.win()
  return {
    rows = state.rows,
    visible = state.view:visible(),
    cursor = win and vim.api.nvim_win_get_cursor(win)[1],
    focused = window.is_focused(),
  }
end

---@param buf integer
---@param lnum integer
---@param marks vim.api.keyset.set_extmark[] From `render.state_marks`.
local function mark_row(buf, lnum, marks)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(
      buf,
      rows_ns,
      lnum - 1,
      0,
      vim.tbl_extend("force", mark, { end_row = lnum, strict = false })
    )
  end
end

---Mark the rows `changeset.position` says are selected, where you are, and last opened.
function M.paint()
  local state = sidebar_state.current()
  local buf, win = window.buf(), window.win()
  if not (state and buf and win) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, rows_ns, 0, -1)
  local width = vim.api.nvim_win_get_width(win)
  for _, mark in ipairs(state.position:marks(M.view())) do
    mark_row(buf, mark.lnum, render.state_marks(mark.kind, width))
  end
end

---@param buf integer
---@param lines changeset.Line[] Rendered lines, each carrying its own marks.
local function apply_marks(buf, lines)
  for lnum, line in ipairs(lines) do
    for _, mark in ipairs(line.marks or {}) do
      vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, mark.col or 0, {
        end_col = mark.end_col,
        hl_group = mark.hl,
        virt_text = mark.virt_text,
        virt_text_pos = mark.pos,
        hl_mode = mark.hl_mode,
        virt_lines = mark.virt_lines,
        priority = mark.priority or render.MARK_PRIORITY,
      })
    end
  end
end

---Hang the "what is being hidden" note under the tree as a virtual line.
---@param buf integer
---@param anchor_line integer 0-based line the note hangs under.
---@param note string? From `render.hidden_note`, fitted to one cell less than the sidebar for its leading space.
local function hidden_note_line(buf, anchor_line, note)
  if note then
    -- A virtual line rather than a row: the cursor cannot reach it, so it needs no
    -- place among the view's rows and no guard in everything that reads a row off a line.
    vim.api.nvim_buf_set_extmark(buf, ns, anchor_line, 0, {
      virt_lines = { { { "" } }, { { " " .. note, render.META_HL } } },
    })
  end
end

---What the header says about the branch, as the tree stands.
---@return changeset.Summary
local function summary()
  local state = sidebar_state.current()
  assert(state, "changeset: no tree built yet")
  local added, removed, readable, pending = 0, 0, 0, 0
  for _, file in ipairs(state.tree.files) do
    added, removed = added + (file.added or 0), removed + (file.removed or 0)
    -- A deleted file's symbols are never read.
    if file.status ~= "deleted" then
      readable = readable + 1
      pending = pending + (Rows.read_status(file, state.tree.symbols) == "reading" and 1 or 0)
    end
  end
  return {
    ref = state.tree.ref,
    pr = state.tree.pr,
    files = #state.tree.files,
    commits = state.tree.commits,
    added = added,
    removed = removed,
    reading = pending > 0 and { done = readable - pending, total = readable } or nil,
  }
end

---Scroll the header's totals into view while the tree is at its top. Virtual lines
---above the first line are filler, which Neovim leaves out of view unless asked.
---@param win integer
function M.reveal_header(win)
  vim.api.nvim_win_call(win, function()
    local at = vim.fn.winsaveview()
    if at.topline == 1 and at.topfill < HEADER_LINES then
      vim.fn.winrestview({ topfill = HEADER_LINES })
    end
  end)
end

---Put the ref in the winbar and hang the totals above the tree's first line.
---@param buf integer
---@param win integer
---@param width integer
local function draw_header(buf, win, width)
  local state = sidebar_state.current()
  assert(state, "changeset: no tree built yet")
  local header = summary()
  vim.wo[win].winbar = render.header(header, width)
  -- Totals before the first diff would claim that nothing changed.
  if state.tree.collected then
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
      virt_lines = { render.header_totals(header, width), { { "" } } },
      virt_lines_above = true,
    })
  end
  M.reveal_header(win)
end

---Draw the sidebar's view of the tree, then its header and row states.
---@param kinds_key string|false? The key bound to the kind menu, which the hidden-kinds note names.
function M.draw(kinds_key)
  local state = sidebar_state.current()
  local buf, win = window.buf(), window.win()
  if not (buf and win and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  assert(state, "changeset: no tree built yet")

  local width = vim.api.nvim_win_get_width(win)
  local lines, lnum =
    state.view:show(state.rows, { icon = icon_for, width = width, cursor = vim.api.nvim_win_get_cursor(win)[1] })

  local text = vim.tbl_map(function(line)
    return line.text
  end, lines)
  if #text == 0 and state.tree.collected then
    text = {
      render.empty_message({
        on_default_branch = state.tree.branch == state.tree.default_branch,
        branch = state.tree.branch,
        ref = state.tree.ref,
      }),
    }
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
  vim.bo[buf].modifiable = false
  -- Rows are trimmed to the width; the sentence standing in for them is not.
  vim.wo[win].wrap = #lines == 0

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  apply_marks(buf, lines)
  local hiding = view.hiding(view.kind_counts(state.rows), state.view:hidden())
  hidden_note_line(buf, #text - 1, render.hidden_note(hiding, width - 1, kinds_key))

  vim.api.nvim_win_set_cursor(win, { lnum, 0 })

  draw_header(buf, win, width)
  M.paint()
end

return M
