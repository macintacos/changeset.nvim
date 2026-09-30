---Puts the session's tree on the sidebar's buffer, through the pure `render`: lines, marks, header and row states.
---`draw` also records the row on each line in the session's `visible`; `band_for` builds a row's preview band.

local build = require("changeset.build")
local icons = require("changeset.icons")
local render = require("changeset.render")
local state = require("changeset.state")
local tree = require("changeset.tree")
local view = require("changeset.view")
local window = require("changeset.window")

-- The totals row over the tree and the blank one under it.
local HEADER_LINES = 2

local M = {}

local ns = vim.api.nvim_create_namespace("changeset")
-- Separate from `ns` so the tracker can repaint row backgrounds without redrawing the tree.
local rows_ns = vim.api.nvim_create_namespace("changeset.rows")

---The tree `build` keeps, with the sidebar's own fields on it.
---Read it again after anything that can replace the tree: `build.build()`, `vim.wait`, a later callback.
---@return changeset.Session?
local function current()
  return build.current() --[[@as changeset.Session?]]
end

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
  local session = current()
  if not session then
    return nil
  end
  local win = window.win()
  if not win then
    return nil
  end
  return session.visible[vim.api.nvim_win_get_cursor(win)[1]]
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

---The ids of the rows on screen; errors when there is no session.
---@return string[] ids Of the rows on screen, in display order.
function M.visible_ids()
  local session = current()
  assert(session, "changeset: no open session")
  return vim.tbl_map(function(row)
    return row.id
  end, session.visible)
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

---Mark the row under the sidebar's cursor as selected while the sidebar has focus,
---the row for where you are, and the row last opened, each of the last two on its
---nearest ancestor on screen. A row several would mark shows the first of those.
function M.paint()
  local session = current()
  local buf, win = window.buf(), window.win()
  if not (session and buf and win) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, rows_ns, 0, -1)
  local ids = M.visible_ids()
  ---@param row changeset.Row?
  ---@return integer?
  local function on_screen(row)
    return row and state._nearest(ids, row.id)
  end
  local here, picked = session.here, session.picked
  local states = {
    { "selected", window.is_focused() and M.row_at_cursor() and vim.api.nvim_win_get_cursor(win)[1] },
    { "here", on_screen(here and tree.locate(session.rows, here.path, here.lnum)) },
    { "picked", on_screen(picked and tree.relocate(session.rows, picked)) },
  }
  local width, taken = vim.api.nvim_win_get_width(win), {}
  for _, entry in ipairs(states) do
    local kind, lnum = entry[1], entry[2]
    if lnum and not taken[lnum] then
      taken[lnum] = true
      mark_row(buf, lnum, render.state_marks(kind, width))
    end
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
    -- place in `visible` and no guard in everything that reads a row off a line.
    vim.api.nvim_buf_set_extmark(buf, ns, anchor_line, 0, {
      virt_lines = { { { "" } }, { { " " .. note, render.META_HL } } },
    })
  end
end

---What the header says about the branch, as the tree stands.
---@return changeset.Summary
local function summary()
  local session = current()
  assert(session, "changeset: no open session")
  local added, removed, readable, pending = 0, 0, 0, 0
  for _, file in ipairs(session.files) do
    added, removed = added + (file.added or 0), removed + (file.removed or 0)
    -- A deleted file's symbols are never read.
    if file.status ~= "deleted" then
      readable = readable + 1
      pending = pending + (session.symbols[file.path] == nil and 1 or 0)
    end
  end
  return {
    ref = session.ref,
    pr = session.pr,
    files = #session.files,
    commits = session.commits,
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
  local session = current()
  assert(session, "changeset: no open session")
  local header = summary()
  vim.wo[win].winbar = render.header(header, width)
  -- Totals before the first diff would claim that nothing changed.
  if session.collected then
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
      virt_lines = { render.header_totals(header, width), { { "" } } },
      virt_lines_above = true,
    })
  end
  M.reveal_header(win)
end

---Draw the tree from the session's current view state, then its header and row states.
---@param kinds_key string|false? The key bound to the kind menu, which the hidden-kinds note names.
function M.draw(kinds_key)
  local session = current()
  local buf, win = window.buf(), window.win()
  if not (buf and win and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  assert(session, "changeset: no open session")

  local previous_row = M.row_at_cursor()
  local previous_line = vim.api.nvim_win_get_cursor(win)[1]
  local width = vim.api.nvim_win_get_width(win)

  local shown = tree.compress(view.by_kind(view.filter(session.rows, session.query), session.hidden), function(id)
    return state.is_chain_open(session.st, id)
  end)

  -- `render.lines` walks the tree for its guides, so it is the one place that
  -- decides which rows are on screen; each line carries its row back, which is
  -- how a cursor line maps to a row without re-deriving that walk here.
  local lines = render.lines(shown, {
    icon = icon_for,
    collapsed = function(id)
      return state.is_collapsed(session.st, id)
    end,
    width = width,
    query = session.query,
  })

  session.visible = vim.tbl_map(function(line)
    return line.row
  end, lines)

  local text = vim.tbl_map(function(line)
    return line.text
  end, lines)
  if #text == 0 and session.collected then
    text = {
      render.empty_message({
        on_default_branch = session.branch == session.default_branch,
        branch = session.branch,
        ref = session.ref,
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
  local hiding = view.hiding(view.kind_counts(session.rows), session.hidden)
  hidden_note_line(buf, #text - 1, render.hidden_note(hiding, width - 1, kinds_key))

  vim.api.nvim_win_set_cursor(win, { state._reanchor(session.visible, previous_row, previous_line), 0 })

  draw_header(buf, win, width)
  M.paint()
end

return M
