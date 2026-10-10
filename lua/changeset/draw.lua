---Puts the tree on the sidebar's buffer, through the pure `render`: the Comments section over its sections, lines,
---marks, header and row states. The sidebar state's View decides what is on each line; `band_for` builds a row's
---preview band.

local comment_store = require("changeset.comment_store")
local highlights = require("changeset.highlights")
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
-- The header's totals, the gaps between sections and the hidden-kinds note: redrawn whole, while `ns` is redrawn only
-- where the lines changed.
local frame_ns = vim.api.nvim_create_namespace("changeset.frame")

---What the last draw put on the buffer, so the next one replaces only the blocks that changed.
---@type { buf: integer, blocks: changeset.view.Block[], tick: integer }?
local previous

---The Comments section as last drawn, kept so a repaint reads no comments from disk.
---@type changeset.Row?
local comments_section

---@param row changeset.Row
---@return string glyph, string hl
local function icon_for(row)
  if row.comments then
    return render.COMMENTS_ICON, highlights.REVIEW_COMMENT_HL
  end
  if row.kind == "section" then
    return icons.get("directory", row.icon)
  end
  if row.kind == "file" or row.kind == "comment" then
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
  local lnum = window.cursor()
  if not lnum then
    return nil
  end
  return state.view:row(lnum)
end

---The rows a preview of `row` stands for, which its bar marks: a symbol's body or an orphan hunk's lines.
---@param row changeset.Row
---@return changeset.BarSpan?
local function span_of(row)
  if not row.range or (row.kind ~= "symbol" and row.kind ~= "orphan") then
    return nil
  end
  local glyph, hl = icon_for(row)
  -- An orphan row is drawn dimmed, and its icon with it.
  return {
    first = row.range[1],
    last = row.range[2],
    icon = glyph,
    icon_hl = row.kind == "orphan" and highlights.META_HL or hl,
  }
end

---The preview band's contents for `row`.
---@param row changeset.Row
---@param jump (string|false)? The jump key the sidebar bound.
---@return changeset.Band
function M.band_for(row, jump)
  local glyph, hl = icons.get("file", row.path)
  local deleted = row.kind == "file" and row.status == "deleted"
  return {
    icon = glyph,
    icon_hl = highlights.band_icon(hl),
    path = row.path,
    span = span_of(row),
    -- Only a symbol row names its destination. An orphan hunk's own text is the
    -- changed line, which is not a place and does not read as one. The jump key opens
    -- nothing on a deleted file, so its band says why instead.
    destination = deleted and "deleted on this branch" or row.kind == "symbol" and row.name or nil,
    jump = jump,
  }
end

---The Comments section for `tree`'s repository, from the comments on disk.
---@param tree changeset.Tree
---@return changeset.Row?
local function comments_for(tree)
  return Rows.comments(comment_store.list(tree.root))
end

---The tree as the sidebar lays it out: the Comments section, while it lists anything, over `rows`.
---@param rows changeset.Row[]
---@return changeset.Row[]
local function laid_out(rows)
  return comments_section and { comments_section, unpack(rows) } or rows
end

---The sidebar as drawn, for `changeset.position`; errors before the first build.
---@return changeset.position.View
function M.view()
  local state = sidebar_state.current()
  assert(state, "changeset: no tree built yet")
  return {
    rows = laid_out(state.rows),
    visible = state.view:visible(),
    cursor = window.cursor(),
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
---@param first integer 0-based line the first of `lines` is on.
local function apply_marks(buf, lines, first)
  for i, line in ipairs(lines) do
    for _, mark in ipairs(line.marks or {}) do
      vim.api.nvim_buf_set_extmark(buf, ns, first + i - 1, mark.col or 0, {
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
    vim.api.nvim_buf_set_extmark(buf, frame_ns, anchor_line, 0, {
      virt_lines = { { { "" } }, { { " " .. note, highlights.META_HL } } },
    })
  end
end

---What the header says about the branch, as the tree stands.
---@param state changeset.SidebarState
---@return changeset.Summary
local function summary(state)
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
    kind = state.tree.kind,
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

---Whether the totals hang over `buf`'s first line.
---@param buf integer
---@return boolean
local function has_header(buf)
  return vim.iter(vim.api.nvim_buf_get_extmarks(buf, frame_ns, 0, 0, { details = true })):any(function(mark)
    return mark[4].virt_lines_above == true
  end)
end

---Put the ref in the winbar and hang the totals above the tree's first line.
---@param buf integer
---@param win integer
---@param width integer
---@param state changeset.SidebarState
---@param topfill integer? The header rows showing before the redraw, kept rather than revealed when given.
local function draw_header(buf, win, width, state, topfill)
  local header = summary(state)
  vim.wo[win].winbar = render.header(header, width)
  -- Totals before the first diff would claim that nothing changed.
  if state.tree.collected then
    vim.api.nvim_buf_set_extmark(buf, frame_ns, 0, 0, {
      virt_lines = { render.header_totals(header, width), { { "" } } },
      virt_lines_above = true,
    })
  end
  if topfill then
    vim.api.nvim_win_call(win, function()
      if vim.fn.winsaveview().topline == 1 then
        vim.fn.winrestview({ topfill = topfill })
      end
    end)
  else
    M.reveal_header(win)
  end
end

---Scroll `win` by the lines its cursor's row moved, so the row keeps its place on screen.
---@param win integer
---@param top integer The window's top line before the row moved.
---@param moved integer Down for positive.
local function hold_place(win, top, moved)
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = math.max(1, top + moved) })
  end)
  M.reveal_header(win)
end

---Whether `win`, scrolled to its top with the header's rows showing, shows line `lnum` and the `'scrolloff'` rows
---below it, which Neovim would otherwise scroll in.
---@param win integer
---@param lnum integer
---@return boolean
local function in_view_from_top(win, lnum)
  local height = vim.fn.winheight(win)
  local so = math.min(vim.wo[win].scrolloff, math.floor((height - 1) / 2))
  local last = math.min(lnum - 1 + so, vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)) - 1)
  return vim.api.nvim_win_text_height(win, { end_row = last }).all <= height
end

---A string that two marks share only when they draw alike.
---@param mark changeset.Mark
---@return string
local function mark_key(mark)
  local parts = {
    mark.col or "",
    mark.end_col or "",
    mark.hl or "",
    mark.pos or "",
    mark.hl_mode or "",
    mark.priority or "",
    mark.virt_lines and vim.inspect(mark.virt_lines) or "",
  }
  for _, chunk in ipairs(mark.virt_text or {}) do
    parts[#parts + 1] = chunk[1] .. "\2" .. (chunk[2] or "")
  end
  return table.concat(parts, "\1")
end

---A string that two blocks share only when they draw the same lines and marks, kept on the block.
---@param block changeset.view.Block
---@return string
local function block_key(block)
  if not block.key then
    local parts = {}
    for _, line in ipairs(block.lines) do
      parts[#parts + 1] = line.text
      for _, mark in ipairs(line.marks) do
        parts[#parts + 1] = mark_key(mark)
      end
      parts[#parts + 1] = "\3"
    end
    block.key = table.concat(parts, "\4")
  end
  return block.key
end

---@param blocks changeset.view.Block[]
---@param first integer
---@param last_index integer
---@return changeset.Line[]
local function lines_of(blocks, first, last_index)
  local out = {}
  for i = first, last_index do
    vim.list_extend(out, blocks[i].lines)
  end
  return out
end

---Replace the lines from `first` to `last_line` (0-based, exclusive) with `text`, marked as `lines` are.
---@param buf integer
---@param first integer
---@param last_line integer
---@param text string[]
---@param lines changeset.Line[]
local function replace(buf, first, last_line, text, lines)
  -- Before the lines go: a replaced line's marks would otherwise slide onto the line after it.
  vim.api.nvim_buf_clear_namespace(buf, ns, first, last_line)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, first, last_line, false, text)
  vim.bo[buf].modifiable = false
  apply_marks(buf, lines, first)
end

---@param buf integer
---@param first integer
---@param last_line integer
---@param lines changeset.Line[]
local function replace_lines(buf, first, last_line, lines)
  replace(
    buf,
    first,
    last_line,
    vim.tbl_map(function(line)
      return line.text
    end, lines),
    lines
  )
end

---Lines before each of `blocks`, and after the last.
---@param blocks changeset.view.Block[]
---@return integer[]
local function offsets(blocks)
  local out = { 0 }
  for i, block in ipairs(blocks) do
    out[i + 1] = out[i] + #block.lines
  end
  return out
end

---Replace the runs of `blocks` that differ from `was`, the blocks on `buf` now.
---@param buf integer
---@param was changeset.view.Block[]
---@param blocks changeset.view.Block[]
local function replace_changed(buf, was, blocks)
  -- Each distinct block as one diff line, so `vim.text.diff` finds the runs that changed.
  local ids, count = {}, 0
  local function tokens(list)
    local out = {}
    for i, block in ipairs(list) do
      local key = block_key(block)
      if not ids[key] then
        count = count + 1
        ids[key] = tostring(count)
      end
      out[i] = ids[key]
    end
    return #out > 0 and table.concat(out, "\n") .. "\n" or ""
  end
  local hunks = vim.text.diff(tokens(was), tokens(blocks), { result_type = "indices" }) --[[@as integer[][] ]]
  local was_at = offsets(was)
  -- Last first, so the lines above each run are where the last draw left them.
  for i = #hunks, 1, -1 do
    local old_start, old_count, new_start, new_count = unpack(hunks[i])
    old_start = old_count == 0 and old_start + 1 or old_start
    new_start = new_count == 0 and new_start + 1 or new_start
    replace_lines(
      buf,
      was_at[old_start],
      was_at[old_start + old_count],
      lines_of(blocks, new_start, new_start + new_count - 1)
    )
  end
end

---Put `blocks` on `buf`, replacing only the runs of blocks that differ from the last draw's.
---@param buf integer
---@param blocks changeset.view.Block[]
local function put(buf, blocks)
  -- Only while nothing else has changed the buffer since: its lines are then the last draw's.
  local was = previous
      and previous.buf == buf
      and vim.api.nvim_buf_get_changedtick(buf) == previous.tick
      and previous.blocks
    or nil
  local at = offsets(blocks)
  if not was then
    replace_lines(buf, 0, -1, lines_of(blocks, 1, #blocks))
  else
    replace_changed(buf, was, blocks)
  end
  previous = at[#at] > 0 and { buf = buf, blocks = blocks, tick = vim.api.nvim_buf_get_changedtick(buf) } or nil
end

---Hang the gap between sections under each section's last line.
---@param buf integer
---@param blocks changeset.view.Block[]
local function section_gaps(buf, blocks)
  local lnum = 0
  for i, block in ipairs(blocks) do
    if block.header and i > 1 then
      vim.api.nvim_buf_set_extmark(
        buf,
        frame_ns,
        lnum - 1,
        0,
        { virt_lines = render.SECTION_GAP, priority = render.MARK_PRIORITY }
      )
    end
    lnum = lnum + #block.lines
  end
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
  local cursor, top = vim.api.nvim_win_get_cursor(win)[1], vim.fn.line("w0", win)
  comments_section = comments_for(state.tree)
  local tree = laid_out(state.rows)
  local lines, lnum, blocks = state.view:show(tree, { icon = icon_for, width = width, cursor = cursor })

  -- Read before the lines go, which takes the header's filler rows with them.
  local saved = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  local topfill = has_header(buf) and saved.topfill or nil
  -- A filter narrowing every row away leaves the lines empty: the footer names the filter, and the branch did change.
  if #tree == 0 and state.tree.collected then
    previous = nil
    replace(buf, 0, -1, {
      render.empty_message({
        on_default_branch = state.tree.branch == state.tree.default_branch,
        branch = state.tree.branch,
        ref = state.tree.ref,
      }),
    }, {})
  else
    put(buf, blocks)
  end
  -- Rows are trimmed to the width; the sentence standing in for them is not.
  vim.api.nvim_set_option_value("wrap", #lines == 0, { win = win, scope = "local" })

  vim.api.nvim_buf_clear_namespace(buf, frame_ns, 0, -1)
  section_gaps(buf, blocks)
  local hiding = view.hiding(view.kind_counts(state.rows), state.view:hidden())
  hidden_note_line(buf, vim.api.nvim_buf_line_count(buf) - 1, render.hidden_note(hiding, width - 1, kinds_key))

  vim.api.nvim_win_set_cursor(win, { lnum, 0 })
  if lnum == cursor then
    -- Replacing the run that holds the top line lets Neovim scroll, though nothing above the cursor moved.
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview({ topline = saved.topline, topfill = saved.topfill })
    end)
  end
  -- After the header, whose rows decide whether the cursor's row still fits under the top.
  draw_header(buf, win, width, state, topfill)
  if lnum ~= cursor and not (top == 1 and in_view_from_top(win, lnum)) then
    hold_place(win, top, lnum - cursor)
  end
  M.paint()
end

---Forget what was drawn, so the next draw puts every line afresh.
function M._forget()
  previous = nil
  view._forget()
end

return M
