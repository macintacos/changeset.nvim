---Draws each review comment's whole text as a block under its last line, and parks the cursor on a block a one-line
---move reaches, as if it were a line of the file.
local config = require("changeset.config")
local dialog = require("changeset.dialog")
local render = require("changeset.render")
local review_comment_window = require("changeset.review_comment_window")

local M = {}

local ns = vim.api.nvim_create_namespace("changeset.review_comment_blocks")

-- The review comment window's measure, so a block reads as that window collapsed.
local MAX_WIDTH = 72
local HINT = " <CR> edit · d delete "
local ELLIPSIS = "…"
local SOLID = { h = "─", v = "│" }
local DASHED = { h = "┄", v = "┆" }

-- Every map of ours carries one of these, so taking ours out never takes out a map someone set over it.
local MOVE_DESC = "Move, stopping on review comment blocks"
local RUN_DESC = "Run what this key does without review comment blocks"
local PARKED_DESCS = { "Edit the review comment", "Delete the review comment", "Step off the review comment" }
local OURS = { [MOVE_DESC] = true, [RUN_DESC] = true }
for _, desc in ipairs(PARKED_DESCS) do
  OURS[desc] = true
end

---@class changeset.BlockMove
---@field key string
---@field down boolean
---@field plug string Holds what `key` did before, which the map runs when it doesn't park.

---@type changeset.BlockMove[]
local MOVES = {
  { key = "j", down = true, plug = "<Plug>(changeset-block-j)" },
  { key = "<Down>", down = true, plug = "<Plug>(changeset-block-down)" },
  { key = "gj", down = true, plug = "<Plug>(changeset-block-gj)" },
  { key = "k", down = false, plug = "<Plug>(changeset-block-k)" },
  { key = "<Up>", down = false, plug = "<Plug>(changeset-block-up)" },
  { key = "gk", down = false, plug = "<Plug>(changeset-block-gk)" },
}

---@class changeset.BufferBlocks
---@field anchors table<integer, changeset.ReviewComment[]> Each extmark's comments, in store order, top first.
---@field widest integer The measure they were drawn at.

---@class changeset.ParkedBlock
---@field win integer
---@field buf integer
---@field id integer The extmark holding its stack.
---@field index integer Its place in the stack, top first.
---@field pos integer[] Where the cursor waits, its column kept for stepping off.
---@field curswant integer The column the cursor wanted when it parked, which a later `j` or `k` keeps to.
---@field cursorline boolean The window's 'cursorline' before parking.
---@field maps table<string, table> The buffer's own maps the block's keys stood in for.

---Whether blocks show, once toggled; until then `review_comment.blocks` decides.
---@type boolean?
local toggled

---@type table<integer, changeset.BufferBlocks>
local drawn = {}

---Each buffer with the movement maps, and its own maps they stood in for.
---@type table<integer, table<string, table>>
local moves = {}

---@type changeset.ParkedBlock?
local parked

---Each buffer's lines whose blocks hide while a review comment window is open on them, its room alone under the line.
---@type table<integer, table<integer, integer>>
local editing = {}

---The window the last parked block was in and the 'cursorline' it gave back, for a split made as it let go.
---@type { win: integer, cursorline: boolean }?
local released

---@param text string
---@return integer
local function cells(text)
  return vim.fn.strdisplaywidth(text)
end

---Whether review comments show as blocks.
---@return boolean
function M.shown()
  if toggled == nil then
    return config.get().review_comment.blocks
  end
  return toggled
end

---Shows review comments as blocks in every buffer, or as their marks alone.
---@param on boolean
function M.show(on)
  toggled = on
  require("changeset.review_comments").redraw()
end

---Switches every buffer between blocks and marks.
function M.toggle()
  M.show(not M.shown())
end

---The widest box inside `buf`'s narrowest window, borders excluded.
---@param buf integer
---@return integer
local function measure(buf)
  local room = MAX_WIDTH + 2
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    room = math.min(room, vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff)
  end
  return math.max(room - 2, 3)
end

---`text` cut to at most `room` cells, ending in an ellipsis when cut.
---@param text string
---@param room integer
---@return string
local function fit(text, room)
  if cells(text) <= room then
    return text
  end
  local n = vim.fn.strchars(text)
  while n > 0 and cells(vim.fn.strcharpart(text, 0, n)) > room - cells(ELLIPSIS) do
    n = n - 1
  end
  return vim.fn.strcharpart(text, 0, n) .. ELLIPSIS
end

---`comment`'s box as virtual lines, at most `widest` cells inside its border.
---@param comment changeset.ReviewComment
---@param widest integer
---@param is_parked boolean
---@return [string, string][][]
local function box(comment, widest, is_parked)
  local edge = comment.draft and DASHED or SOLID
  local plain_border = comment.draft and render.BLOCK_DRAFT_HL or render.BLOCK_BORDER_HL
  local border = is_parked and render.BLOCK_PARKED_HL or plain_border
  local label = require("changeset.review_comments").lines_label(comment.start_line or comment.line, comment.line)
  -- Named as hover names it.
  local title = (comment.draft and " Draft review comment · " or " Review comment · ") .. label .. " "
  local text = dialog.wrap(vim.trim((comment.body:gsub("\r\n", "\n"))), math.max(widest - 2, 1))
  local inner = cells(title) + 1
  for _, line in ipairs(text) do
    inner = math.max(inner, cells(line) + 2)
  end
  inner = math.min(inner, widest)
  -- At least one cell of border after the title, so a cut one still reads as sitting in the border.
  title = fit(title, inner - 1)
  local lines = {
    {
      { "╭", border },
      {
        title,
        is_parked and render.BLOCK_PARKED_TITLE_HL or comment.draft and render.BLOCK_DRAFT_HL or render.BLOCK_TITLE_HL,
      },
      { edge.h:rep(inner - cells(title)), border },
      { "╮", border },
    },
  }
  for _, line in ipairs(text) do
    local padded = " " .. line .. (" "):rep(math.max(inner - cells(line) - 1, 0))
    lines[#lines + 1] = { { edge.v, border }, { padded, render.BLOCK_BODY_HL }, { edge.v, border } }
  end
  local bottom = { { "╰", border } }
  local rest = inner
  if is_parked and cells(HINT) < inner then
    bottom[#bottom + 1] = { HINT, render.BLOCK_HINT_HL }
    rest = inner - cells(HINT)
  end
  vim.list_extend(bottom, { { edge.h:rep(rest), border }, { "╯", border } })
  lines[#lines + 1] = bottom
  return lines
end

---The line extmark `id` of `buf` sits on now, 1-based: edits move it off its comments' stored line.
---@param buf integer
---@param id integer
---@return integer
local function anchor_line(buf, id)
  return vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, {})[1] + 1
end

---The extmark holding the blocks under line `line` of `buf`, if any.
---@param buf integer
---@param line integer
---@return integer?
local function anchor_at(buf, line)
  if not drawn[buf] or line < 1 then
    return
  end
  if editing[buf] and editing[buf][line] then
    return
  end
  local mark = vim.api.nvim_buf_get_extmarks(buf, ns, { line - 1, 0 }, { line - 1, -1 }, { limit = 1 })[1]
  return mark and mark[1]
end

---Redraws extmark `id`'s stack, block `parked_index` parked.
---@param buf integer
---@param id integer
---@param parked_index integer?
local function paint(buf, id, parked_index)
  local blocks = drawn[buf]
  local line = anchor_line(buf, id)
  local lines = {}
  if not (editing[buf] and editing[buf][line]) then
    for i, comment in ipairs(blocks.anchors[id]) do
      vim.list_extend(lines, box(comment, blocks.widest, i == parked_index))
    end
  end
  vim.api.nvim_buf_set_extmark(buf, ns, line - 1, 0, { id = id, virt_lines = lines })
end

---`buf`'s map of `lhs` in Normal mode, else the global one; empty when neither.
---@param buf integer
---@param lhs string
---@return table
local function map_of(buf, lhs)
  return vim.api.nvim_buf_call(buf, function()
    return vim.fn.maparg(lhs, "n", false, true)
  end)
end

---Takes our maps of `saved`'s keys out of `buf`, putting back the buffer's own maps they stood in for; a map set
---over ours since stays.
---@param buf integer
---@param saved table<string, table>
local function restore(buf, saved)
  for lhs, map in pairs(saved) do
    local current = map_of(buf, lhs)
    if current.buffer == 1 and OURS[current.desc] then
      vim.keymap.del("n", lhs, { buffer = buf })
    end
    if map.buffer == 1 and not (current.buffer == 1 and not OURS[current.desc]) then
      vim.api.nvim_buf_call(buf, function()
        vim.fn.mapset("n", false, map)
      end)
    end
  end
end

---Lets go of the parked block, if any.
local function unpark()
  local state = parked
  if not state then
    return
  end
  parked = nil
  if drawn[state.buf] and drawn[state.buf].anchors[state.id] then
    paint(state.buf, state.id, nil)
  end
  if vim.api.nvim_buf_is_valid(state.buf) then
    restore(state.buf, state.maps)
  end
  dialog.show_cursor()
  local just_released = { win = state.win, cursorline = state.cursorline }
  released = just_released
  -- Only a split made as the block lets go; a later one copies the window's own value.
  vim.schedule(function()
    if released == just_released then
      released = nil
    end
  end)
  if vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_option_value("cursorline", state.cursorline, { scope = "local", win = state.win })
  end
end

---Rows of the current window from its first screen row to the end of line `line`, its filler included.
---@param view vim.fn.winsaveview.ret
---@param line integer
---@return integer
local function rows_through(view, line)
  local hidden = vim.api.nvim_win_text_height(0, { start_row = view.topline - 1, end_row = view.topline - 1 }).fill
    - view.topfill
  return vim.api.nvim_win_text_height(0, { start_row = view.topline - 1, end_row = line - 1 }).all - hidden
end

---Rows line `line` takes, its filler above it left out.
---@param line integer
---@return integer
local function text_rows(line)
  local height = vim.api.nvim_win_text_height(0, { start_row = line - 1, end_row = line - 1 })
  return height.all - height.fill
end

---Screen rows, from the top of the current window, of the first and last row of the parked block in `state`; 0
---for both while it is above the window.
---@param state changeset.ParkedBlock
---@param view vim.fn.winsaveview.ret
---@return integer first
---@return integer last
local function block_rows(state, view)
  local line = anchor_line(state.buf, state.id)
  local blocks = drawn[state.buf]
  local above, height = 0, 0
  for i, comment in ipairs(blocks.anchors[state.id]) do
    local rows = #box(comment, blocks.widest, false)
    if i < state.index then
      above = above + rows
    elseif i == state.index then
      height = rows
    end
  end
  local next_line = line + 1
  local last
  if next_line > vim.api.nvim_buf_line_count(state.buf) and line >= view.topline then
    last = rows_through(view, line) + above + height
  elseif next_line >= view.topline then
    -- The stack heads the filler above the next line, ahead of other marks' virtual lines there, such as gitsigns'
    -- deleted lines.
    local filler = vim.api.nvim_win_text_height(0, { start_row = line, end_row = line }).fill
    last = rows_through(view, next_line) - text_rows(next_line) - filler + above + height
  else
    return 0, 0
  end
  return last - height + 1, last
end

---Scrolls the parked block's window the least that shows the block whole, never scrolling its cursor off.
---@param state changeset.ParkedBlock
local function reveal(state)
  vim.api.nvim_win_call(state.win, function()
    local win_height = vim.api.nvim_win_get_height(0)
    local at = vim.api.nvim_win_get_cursor(0)[1]
    for _ = 1, win_height do
      local view = vim.fn.winsaveview()
      local first, last = block_rows(state, view)
      local cursor_last = rows_through(view, at)
      local cursor_first = cursor_last - text_rows(at) + 1
      if last > win_height and first > 1 and cursor_first > 1 then
        vim.cmd.normal({ vim.keycode("<C-e>"), bang = true })
      elseif first < 1 and cursor_last < win_height then
        vim.cmd.normal({ vim.keycode("<C-y>"), bang = true })
      else
        return
      end
    end
  end)
end

---Parks the cursor of `win`, waiting at `pos`, on block `index` of extmark `id`'s stack in `buf`.
---@param win integer
---@param buf integer
---@param id integer
---@param index integer
---@param pos integer[]
---@param curswant integer? Kept from the block this one steps on from; else read off the window.
local function park(win, buf, id, index, pos, curswant)
  curswant = curswant or vim.api.nvim_win_call(win, vim.fn.winsaveview).curswant
  unpark()
  ---@type changeset.ParkedBlock
  local state = {
    win = win,
    buf = buf,
    id = id,
    index = index,
    pos = pos,
    curswant = curswant,
    cursorline = vim.api.nvim_get_option_value("cursorline", { scope = "local", win = win }),
    maps = {},
  }
  parked = state
  paint(buf, id, index)
  -- The block is what the cursor is on; the line it waits on would read as focused instead.
  dialog.hide_cursor()
  vim.api.nvim_set_option_value("cursorline", false, { scope = "local", win = win })
  local comment = drawn[buf].anchors[id][index]
  ---Runs `verb` on the comment once the block lets go; refuses in a modified buffer, where blocks drift off their
  ---comments' stored lines.
  ---@param verb fun(reviewing: table)
  local function act(verb)
    return function()
      local reviewing = require("changeset.reviewing")
      if vim.bo[buf].modified then
        return vim.notify("Changeset: " .. reviewing.UNSAVED, vim.log.levels.WARN)
      end
      unpark()
      verb(reviewing)
    end
  end
  local function edit(reviewing)
    reviewing.open(comment)
  end
  local keys = {
    { "<CR>", act(edit), PARKED_DESCS[1] },
    { "c", act(edit), PARKED_DESCS[1] },
    {
      "d",
      act(function(reviewing)
        reviewing.ask_delete(comment)
      end),
      PARKED_DESCS[2],
    },
    { "<Esc>", unpark, PARKED_DESCS[3] },
  }
  for _, key in ipairs(keys) do
    state.maps[key[1]] = map_of(buf, key[1])
    vim.keymap.set("n", key[1], key[2], { buffer = buf, nowait = true, desc = key[3] })
  end
  reveal(state)
end

---Moves the cursor of `win` to line `line`, held to its buffer.
---@param win integer
---@param line integer
local function put(win, line)
  local count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
  vim.api.nvim_win_set_cursor(win, { math.max(math.min(line, count), 1), 0 })
end

---Moves from the parked block to the next in its stack, else off it: down to the line under it, up to its line.
---@param state changeset.ParkedBlock
---@param down boolean
local function step(state, down)
  local index = state.index + (down and 1 or -1)
  if drawn[state.buf].anchors[state.id][index] then
    return park(state.win, state.buf, state.id, index, state.pos, state.curswant)
  end
  local line = anchor_line(state.buf, state.id)
  unpark()
  put(state.win, down and line + 1 or line)
  vim.api.nvim_win_call(state.win, function()
    -- Where a plain move would have landed: the column the cursor wanted, held to the line.
    local at = vim.api.nvim_win_get_cursor(0)[1]
    local col = vim.fn.virtcol2col(0, at, math.min(state.curswant + 1, vim.v.maxcol))
    vim.api.nvim_win_set_cursor(0, { at, math.max(col - 1, 0) })
    vim.fn.winrestview({ curswant = state.curswant })
    -- Up lands on the screen row next to the block, a wrapped line's last, at the wanted column within that row.
    local rows = vim.wo.wrap and text_rows(at) or 1
    if not down and rows > 1 and vim.fn.foldclosed(line) == -1 then
      local last = math.max(#vim.api.nvim_get_current_line() - 1, 0)
      vim.api.nvim_win_set_cursor(0, { at, last })
      if state.curswant < vim.v.maxcol then
        vim.cmd.normal({ "g0", bang = true })
        local width = vim.api.nvim_win_get_width(0) - vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].textoff
        local wanted = vim.fn.virtcol(".") + state.curswant % width
        vim.api.nvim_win_set_cursor(0, { at, math.max(vim.fn.virtcol2col(0, at, wanted) - 1, 0) })
        -- On the row's own column, as `gk` would leave it, or the next screen move would jump off the line.
        vim.fn.winrestview({ curswant = wanted - 1 })
      else
        vim.fn.winrestview({ curswant = state.curswant })
      end
    end
  end)
end

---The first line of the closed fold holding `line`, else `line`.
---@param line integer
---@return integer
local function fold_top(line)
  local top = vim.fn.foldclosed(line)
  return top == -1 and line or top
end

---The last line of the closed fold holding `line`, else `line`.
---@param line integer
---@return integer
local function fold_end(line)
  local last = vim.fn.foldclosedend(line)
  return last == -1 and line or last
end

---What a movement key left for the callback that runs after its motion: where it started, and the `on_key` count
---when it was pressed.
---@class changeset.PendingMove
---@field move changeset.BlockMove
---@field win integer
---@field buf integer
---@field before integer[]
---@field view vim.fn.winsaveview.ret
---@field typed string? What `on_key` saw typed for the first key after the map ran: the map's key when typed.

---@type changeset.PendingMove?
local pending

---Whether the user typed `move`'s key, rather than a mapping, `:normal` or `feedkeys` sending it. `on_key` reports a
---mapped key after its map ran, so this is only known once the keys the map returned arrive.
---@param p changeset.PendingMove
---@return boolean
local function typed(p)
  return p.typed == vim.keycode(p.move.key)
end

---Runs `p`'s key as it was mapped before blocks showed, in the real typeahead, so a failing motion still ends the
---macro or mapping around it.
---@param p changeset.PendingMove
local function run_plain(p)
  vim.api.nvim_feedkeys(vim.keycode(p.move.plug), "im", false)
end

---After a typed key's motion: parks on a block it crossed, putting the cursor back.
local function settle()
  local p = pending
  pending = nil
  if not p or not typed(p) or vim.api.nvim_get_current_win() ~= p.win then
    return
  end
  local after = vim.api.nvim_win_get_cursor(p.win)
  local id, index = nil, 1
  if p.move.down then
    if after[1] > fold_end(p.before[1]) then
      id = anchor_at(p.buf, fold_end(p.before[1]))
    end
  else
    local top = fold_top(p.before[1])
    if after[1] < top and fold_end(after[1]) == top - 1 then
      id = anchor_at(p.buf, top - 1)
      index = id and #drawn[p.buf].anchors[id] or 1
    end
  end
  if id then
    vim.fn.winrestview(p.view)
    park(p.win, p.buf, id, index, p.before, p.view.curswant)
  end
end

---Parks on the first block under the cursor's line, for a typed key going down from its last screen row.
local function park_below()
  local p = pending
  pending = nil
  if not p then
    return
  end
  local id = typed(p) and anchor_at(p.buf, fold_end(p.before[1]))
  if not id then
    return run_plain(p)
  end
  park(p.win, p.buf, id, 1, p.before, p.view.curswant)
end

---Moves on from the parked block for a typed key; another lets go and runs the key's motion.
local function step_parked()
  local p = pending
  pending = nil
  if not p then
    return
  end
  if not (typed(p) and parked and parked.win == p.win and parked.buf == p.buf) then
    unpark()
    return run_plain(p)
  end
  step(parked, p.move.down)
end

local SETTLE = "<Plug>(changeset-block-settle)"
local PARK = "<Plug>(changeset-block-park)"
local STEP = "<Plug>(changeset-block-step)"
vim.keymap.set("n", SETTLE, settle, { desc = "Park on a review comment block the last move crossed" })
vim.keymap.set("n", PARK, park_below, { desc = "Park on the review comment block under this line" })
vim.keymap.set("n", STEP, step_parked, { desc = "Step on from the parked review comment block" })

---Whether the cursor is on the last screen row of its line, where a move down leaves it.
---@return boolean
local function on_last_row()
  local line, col = unpack(vim.api.nvim_win_get_cursor(0))
  if not vim.wo.wrap or vim.fn.foldclosed(line) ~= -1 then
    return true
  end
  local text = vim.api.nvim_get_current_line()
  local last = vim.fn.screenpos(0, line, math.max(#text, 1)).row
  return last == 0 or vim.fn.screenpos(0, line, col + 1).row == last
end

---Points `move`'s `<Plug>` in `buf` at what its key does without us: the buffer's own map from before ours, else the
---global map as it is now, else the key itself.
---@param buf integer
---@param move changeset.BlockMove
local function point(buf, move)
  local own = moves[buf][move.key]
  if not next(own) then
    local lhs = vim.fn.keytrans(vim.keycode(move.key))
    own = vim.iter(vim.api.nvim_get_keymap("n")):find(function(map)
      return map.lhs == lhs
    end) or {}
  end
  if next(own) then
    -- A copy, not the key: a map whose rhs starts with its own lhs doesn't remap that key, losing the user's.
    local copy = vim.tbl_extend("force", own, {
      lhs = move.plug,
      lhsraw = vim.keycode(move.plug),
      buffer = 1,
      desc = RUN_DESC,
    })
    copy.lhsrawalt = nil
    vim.api.nvim_buf_call(buf, function()
      vim.fn.mapset("n", false, copy)
    end)
  else
    vim.keymap.set("n", move.plug, move.key, { buffer = buf, desc = RUN_DESC })
  end
end

---The keys `move`'s map sends: its own motion, wrapped so a typed key parks on the blocks it would cross. A count, a
---macro, insert mode's `<C-o>` or a key a mapping sent runs the motion untouched.
---@param move changeset.BlockMove
---@return string
local function expr(move)
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  point(buf, move)
  local plain = vim.v.count > 0 or vim.fn.reg_executing() ~= "" or vim.api.nvim_get_mode().mode ~= "n"
  if plain then
    unpark()
    return move.plug
  end
  pending = {
    move = move,
    win = win,
    buf = buf,
    before = vim.api.nvim_win_get_cursor(win),
    view = vim.fn.winsaveview(),
  }
  if parked and parked.win == win then
    return STEP
  end
  if move.down and anchor_at(buf, fold_end(pending.before[1])) and on_last_row() then
    return PARK
  end
  return move.plug .. SETTLE
end

---Maps the movement keys in `buf`, keeping any map of its own they stand in for.
---@param buf integer
local function map_moves(buf)
  local saved = {}
  moves[buf] = saved
  for _, move in ipairs(MOVES) do
    saved[move.key] = map_of(buf, move.key)
    if saved[move.key].buffer ~= 1 then
      saved[move.key] = {}
    end
    saved[move.plug] = {}
    vim.keymap.set("n", move.key, function()
      return expr(move)
    end, { buffer = buf, expr = true, remap = true, desc = MOVE_DESC })
  end
end

---Takes the movement maps out of `buf`, giving back what they stood in for.
---@param buf integer
local function unmap_moves(buf)
  if moves[buf] then
    restore(buf, moves[buf])
    moves[buf] = nil
  end
end

---Draws `comments`, those of `buf`'s file, as blocks while blocks show, dropping the blocks drawn before.
---@param buf integer
---@param comments changeset.ReviewComment[]
function M.draw(buf, comments)
  if parked and parked.buf == buf then
    unpark()
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  drawn[buf] = nil
  local line_count = vim.api.nvim_buf_line_count(buf)
  comments = vim.tbl_filter(function(comment)
    return comment.line <= line_count
  end, comments)
  if not M.shown() or #comments == 0 then
    return unmap_moves(buf)
  end
  local by_line, lines = {}, {}
  for _, comment in ipairs(comments) do
    if not by_line[comment.line] then
      by_line[comment.line] = {}
      lines[#lines + 1] = comment.line
    end
    table.insert(by_line[comment.line], comment)
  end
  -- One extmark a line: Neovim draws separate marks' virtual lines on one line newest first, not in store order.
  drawn[buf] = { anchors = {}, widest = measure(buf) }
  for _, line in ipairs(lines) do
    local id = vim.api.nvim_buf_set_extmark(buf, ns, line - 1, 0, {})
    drawn[buf].anchors[id] = by_line[line]
    paint(buf, id, nil)
  end
  if not moves[buf] then
    map_moves(buf)
  end
end

---Parks the current window's cursor on the block of the comment on `comment`'s lines, when its buffer draws one.
---@param comment changeset.ReviewComment
function M.select(comment)
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local id = comment.line and anchor_at(buf, comment.line)
  if not id then
    return
  end
  for index, each in ipairs(drawn[buf].anchors[id]) do
    if each.start_line == comment.start_line then
      if vim.api.nvim_win_get_cursor(win)[1] ~= comment.line then
        put(win, comment.line)
      end
      return park(win, buf, id, index, vim.api.nvim_win_get_cursor(win))
    end
  end
end

---Redraws `buf`'s blocks at its windows' measure when that changed, a parked block staying parked.
---@param buf integer
local function refit(buf)
  local blocks = drawn[buf]
  if not blocks or not vim.api.nvim_buf_is_loaded(buf) or measure(buf) == blocks.widest then
    return
  end
  blocks.widest = measure(buf)
  for id in pairs(blocks.anchors) do
    paint(buf, id, parked and parked.buf == buf and parked.id == id and parked.index or nil)
  end
end

local group = vim.api.nvim_create_augroup("changeset.review_comment_blocks", { clear = true })

-- Hides the blocks under the line a review comment window opens on, so its room sits directly under the line, and
-- brings them back as it closes.
review_comment_window.watch(function(window, opened)
  local buf, line = window.source_buf, window.comment.line
  if not line then
    return
  end
  editing[buf] = editing[buf] or {}
  editing[buf][line] = (editing[buf][line] or 0) + (opened and 1 or -1)
  if editing[buf][line] <= 0 then
    editing[buf][line] = nil
  end
  if not (drawn[buf] and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local mark = vim.api.nvim_buf_get_extmarks(buf, ns, { line - 1, 0 }, { line - 1, -1 }, { limit = 1 })[1]
  if mark then
    paint(buf, mark[1], nil)
  end
end)

-- Fires: a mode change, a window or buffer left, or text changed while parked, none of which the block's keys cover.
vim.api.nvim_create_autocmd({ "ModeChanged", "WinLeave", "BufLeave", "TextChanged" }, {
  group = group,
  desc = "changeset: step off a review comment block on any other action",
  callback = function()
    unpark()
  end,
})

-- Fires: a window split off another, which copies its 'cursorline', off while a block is parked there.
vim.api.nvim_create_autocmd("WinNew", {
  group = group,
  desc = "changeset: give a window split off a parked one the cursorline it had before parking",
  callback = function()
    local from = vim.fn.win_getid(vim.fn.winnr("#"))
    local saved = parked and parked.win == from and parked or released and released.win == from and released
    if saved then
      vim.api.nvim_set_option_value("cursorline", saved.cursorline, { scope = "local", win = 0 })
    end
  end,
})

-- Fires: windows resized, which may change the narrowest window their buffers' blocks must fit.
vim.api.nvim_create_autocmd("WinResized", {
  group = group,
  desc = "changeset: refit review comment blocks to their narrowest window",
  callback = function()
    for _, win in ipairs(vim.v.event.windows or {}) do
      if vim.api.nvim_win_is_valid(win) then
        refit(vim.api.nvim_win_get_buf(win))
      end
    end
  end,
})

-- Fires: a buffer shown in a window, which may be narrower than the ones its blocks were drawn for.
vim.api.nvim_create_autocmd("BufWinEnter", {
  group = group,
  desc = "changeset: refit a buffer's review comment blocks to a new window",
  callback = function(args)
    refit(args.buf)
  end,
})

-- Fires: a buffer unloaded, which takes its lines and extmarks with it.
vim.api.nvim_create_autocmd("BufUnload", {
  group = group,
  desc = "changeset: forget the review comment blocks of an unloaded buffer",
  callback = function(args)
    if parked and parked.buf == args.buf then
      unpark()
    end
    drawn[args.buf] = nil
    unmap_moves(args.buf)
  end,
})

---The keys a parked block lets through: its own and the movement keys, `g` only as the start of `gj` or `gk`.
local KEEPS = {}
for _, lhs in ipairs({ "j", "k", "gj", "gk", "<Down>", "<Up>", "<CR>", "c", "d", "<Esc>" }) do
  KEEPS[vim.keycode(lhs)] = true
end
local MOUSE_MOVE = vim.keycode("<MouseMove>")
local after_g = false

-- Records what was typed for the key a movement map ran for, which tells a typed key from one a mapping sent. Any other typed key
-- lets go of a parked block, `zz` and `<C-e>` included, which change neither mode nor text.
vim.on_key(function(_, typed_key)
  if typed_key == MOUSE_MOVE then
    return
  end
  if pending and pending.typed == nil then
    pending.typed = typed_key or ""
  end
  if not parked or not typed_key or typed_key == "" then
    return
  end
  local was_g = after_g
  after_g = typed_key == "g" and not was_g
  if after_g or (KEEPS[typed_key] and (not was_g or typed_key == "j" or typed_key == "k")) then
    return
  end
  vim.schedule(unpark)
end, ns)

return M
