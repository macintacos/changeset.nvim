---Dialogs drawn as changeset's own floats: a question before a destructive action, and a choice among rows.
local cells = require("changeset.cells")
local highlights = require("changeset.highlights")
local render = require("changeset.render")

local M = {}

local ns = vim.api.nvim_create_namespace("changeset.dialog")

-- Prose reads at a short measure, so the body wraps here unless the editor is narrower.
local MEASURE = 44
-- Cells between the border and the text, either side.
local PAD = 2
-- Above other floats and the popup menu (100), under the command line and ui2's message windows (197-200).
local ZINDEX = 150
local QUOTE = "▎ "
-- The button that changes nothing, first and focused so a <CR> typed ahead lands on it.
local SAFE = "Keep"
-- Marks the focused row, at its left edge, where a list is read from.
local BAR = "▌"
-- Rows a digit chooses directly.
local NUMBERED = 9
-- Focus is drawn, so the cursor would only cover it. An entry of its own, apart from the sidebar's "n-v" one, so
-- neither removes the other's.
local NO_CURSOR = "n:" .. highlights.NO_CURSOR_HL

---@class changeset.DialogBlock A paragraph of a dialog's body.
---@field text string
---@field hl? string Group for the text; the float's own when absent.
---@field quote? string Group of a bar drawn before each of its lines, marking it as quoted.
---@field max_lines? integer Lines it may take: past them it is cut, and its last line ends in "…".
---@field path? boolean Keep it to one line, cutting its head when too wide, as a path's tail matters most.

---@class changeset.ConfirmOpts
---@field title string The action it asks about, e.g. "Abandon the review".
---@field body changeset.DialogBlock[]
---@field action string The verb on the button that goes ahead, e.g. "Abandon".

---Text and the group, or stacked groups, it is drawn in.
---@alias changeset.DialogChunk { [1]: string, [2]: string|string[]|nil }

---@alias changeset.DialogLine changeset.DialogChunk[]

---@class changeset.DialogItem A row to choose.
---@field icon? changeset.DialogChunk Drawn before the cells.
---@field cells changeset.DialogChunk[] One per column; each but the row's last is padded to its column's widest.
---@field unavailable? string Why it can't be chosen, drawn after its dimmed cells.

---@class changeset.ChooseOpts
---@field title string What choosing does, e.g. "Submit the review".
---@field items changeset.DialogItem[]
---@field action string The verb for choosing, which the footer names: "submit".
---@field focus? integer|false The row focused at first, false for none; the first that can be chosen when absent.

---@class changeset.DialogFrame
---@field title string
---@field footer? string
---@field width integer Cells inside the border, cut to the editor's.

---@class changeset.DialogState
---@field win integer
---@field buf integer
---@field opener integer The window current when it opened, which gets focus back.
---@field done boolean
---@field answer fun(value: any)

---Hides the normal-mode cursor through a 'guicursor' entry of its own, apart from the sidebar's.
function M.hide_cursor()
  vim.opt.guicursor:append(NO_CURSOR)
end

---Shows the cursor `hide_cursor` hid.
function M.show_cursor()
  vim.opt.guicursor:remove(NO_CURSOR)
end

---The dialog open now, until focus leaves it.
---@type changeset.DialogState?
local active

---`text` in lines at most `width` cells wide, broken between words, and inside a word wider than that. A line keeps
---its indentation and the spaces between its words, save those where it breaks.
---@param text string
---@param width integer
---@return string[]
function M.wrap(text, width)
  local lines = {}
  for _, paragraph in ipairs(vim.split(text, "\n", { plain = true })) do
    local line, first = "", true
    for space, word in paragraph:gmatch("(%s*)(%S+)") do
      if line ~= "" and cells.width(line .. space .. word) <= width then
        line = line .. space .. word
      else
        if line ~= "" then
          lines[#lines + 1] = line
        end
        word = first and space .. word or word
        -- A lone character wider than the measure stays the line's, rather than leave an empty one after it.
        while cells.width(word) > width and vim.fn.strchars(word) > 1 do
          local piece = cells.head(word, width)
          if piece == "" then
            piece = vim.fn.strcharpart(word, 0, 1)
          end
          lines[#lines + 1] = piece
          word = word:sub(#piece + 1)
        end
        line = word
      end
      first = false
    end
    lines[#lines + 1] = line
  end
  return lines
end

---The body's lines: each block wrapped at `width` cells, its quote bar included.
---@param blocks changeset.DialogBlock[]
---@param width integer
---@return changeset.DialogLine[]
function M._body(blocks, width)
  local lines = {}
  for _, block in ipairs(blocks) do
    local bar = block.quote and QUOTE or ""
    local measure = width - cells.width(bar)
    local text = block.text:gsub("%s+$", "")
    local texts
    if block.path then
      texts = {
        cells.width(text) <= measure and text
          or cells.ELLIPSIS .. cells.tail(text, measure - cells.width(cells.ELLIPSIS)),
      }
    else
      texts = M.wrap(text, measure)
      if block.max_lines and #texts > block.max_lines then
        texts = vim.list_slice(texts, 1, block.max_lines)
        texts[#texts] = cells.head(texts[#texts], measure - cells.width(cells.ELLIPSIS)) .. cells.ELLIPSIS
      end
    end
    for _, line in ipairs(texts) do
      lines[#lines + 1] = block.quote and { { bar, block.quote }, { line, block.hl } } or { { line, block.hl } }
    end
  end
  return lines
end

---Cells the editor leaves a dialog's text: its width less the border and `pad` cells either side.
---@param pad integer
---@return integer
local function room(pad)
  return vim.o.columns - 2 - 2 * pad
end

---Writes `lines` into `buf`, colouring each chunk and tinting line `focused` across the window.
---@param buf integer
---@param lines changeset.DialogLine[]
---@param focused integer?
local function paint(buf, lines, focused)
  local composed = vim.tbl_map(function(line)
    return render.compose(nil, line)
  end, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(
    buf,
    0,
    -1,
    false,
    vim.tbl_map(function(line)
      return line.text
    end, composed)
  )
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, line in ipairs(composed) do
    for _, mark in ipairs(line.marks) do
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, mark.col, { end_col = mark.end_col, hl_group = mark.hl })
    end
  end
  if focused then
    vim.api.nvim_buf_set_extmark(buf, ns, focused - 1, 0, { line_hl_group = highlights.DIALOG_SELECTED_HL })
  end
end

---Closes the dialog, gives focus back to the window it opened from, then answers: in that order, so whatever the
---answer opens or focuses is not undone by the close.
---@param state changeset.DialogState
---@param value any
local function finish(state, value)
  if state.done then
    return
  end
  state.done = true
  if active == state then
    active = nil
  end
  -- A dialog opened since, in the same keys as this one's cancel, has focus now; taking it would cancel that one.
  if not active and vim.api.nvim_win_is_valid(state.opener) then
    vim.api.nvim_set_current_win(state.opener)
  end
  if vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  vim.schedule(function()
    state.answer(value)
  end)
end

---Where a dialog `width` by `height` cells inside its border goes: cut to the editor, and centred on it.
---@param width integer
---@param height integer
---@return vim.api.keyset.win_config
local function place(width, height)
  width = math.min(width, vim.o.columns - 2)
  height = math.min(height, math.max(vim.o.lines - vim.o.cmdheight - 4, 1))
  return {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(math.floor((vim.o.lines - vim.o.cmdheight - height - 2) / 2), 0),
    col = math.max(math.floor((vim.o.columns - width - 2) / 2), 0),
  }
end

---Opens and enters a float holding `lines`, centred on the editor; or, while another dialog is open, answers nil
---and opens nothing.
---@param lines changeset.DialogLine[]
---@param frame changeset.DialogFrame
---@param answer fun(value: any) Called once, with nil on a cancel.
---@return changeset.DialogState?
local function open(lines, frame, answer)
  -- A dialog closed under `noautocmd` never ran its leave, so its lock outlives its window. Its cursor entry is the
  -- one this dialog adds again, and removes on closing.
  if active and not vim.api.nvim_win_is_valid(active.win) then
    active = nil
  end
  -- A second dialog, opened from the first by a global key or arriving late from herdr, would take focus, and the
  -- first's leave would then cancel both.
  if active then
    vim.schedule(function()
      answer(nil)
    end)
    return nil
  end
  local title, footer = " " .. frame.title .. " ", frame.footer and " " .. frame.footer .. " "
  local width = math.max(frame.width, cells.width(title), footer and cells.width(footer) or 0)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  -- The margins read as indents, down which mini.indentscope would rule a scope line.
  vim.b[buf].miniindentscope_disable = true
  -- The hidden cursor sits on the focused button, whose label mini.cursorword would underline.
  vim.b[buf].minicursorword_disable = true
  paint(buf, lines)
  local state = {
    buf = buf,
    opener = vim.api.nvim_get_current_win(),
    done = false,
    answer = answer,
  }
  state.win = vim.api.nvim_open_win(
    buf,
    true,
    vim.tbl_extend("force", place(width, #lines), {
      style = "minimal",
      border = "rounded",
      title = { { title, "FloatTitle" } },
      title_pos = "left",
      footer = footer and { { footer, "FloatFooter" } },
      footer_pos = footer and "left",
      zindex = ZINDEX,
    })
  )
  active = state
  M.hide_cursor()
  -- A row wider than the editor is cut at the border, not wrapped onto the next.
  vim.wo[state.win].wrap = false
  -- The float takes its opener's jumplist, so <C-o> would otherwise put a file in it, open and unanswerable.
  vim.wo[state.win].winfixbuf = true
  -- Fires: focus leaving the dialog other than through its keys, or its buffer swapped out anyway, as `:b!` can.
  -- Either cancels it: it is modal while open.
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    buffer = buf,
    desc = "changeset: cancel a dialog whose window or buffer is left",
    callback = function()
      if active == state then
        active = nil
      end
      M.show_cursor()
      -- Closing a window is not allowed while focus is leaving it.
      vim.schedule(function()
        finish(state, nil)
      end)
    end,
  })
  -- scrollEOF.nvim scrolls to leave room past a buffer's end, pushing lines out of a window sized to show them all.
  -- One taller than the editor scrolls as it must.
  local function pin()
    if vim.api.nvim_buf_line_count(buf) <= vim.api.nvim_win_get_height(state.win) then
      vim.api.nvim_win_call(state.win, function()
        vim.fn.winrestview({ topline = 1 })
      end)
    end
  end
  -- Fires: the cursor moving in the dialog, as in the tick it opens, where Neovim fires no WinScrolled for a float
  -- scrolled before its first redraw. scrollEOF's autocmd is older, so it runs first and this one undoes it.
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    desc = "changeset: scroll a dialog back to its first line",
    callback = pin,
  })
  -- Fires: any window scrolling in a later tick, not only the dialog's, since Neovim names just the first of several
  -- that scrolled at once, and a move just before the dialog opened can scroll it a tick late.
  vim.api.nvim_create_autocmd("WinScrolled", {
    desc = "changeset: scroll a dialog back to its first line",
    callback = function()
      if not vim.api.nvim_win_is_valid(state.win) then
        return true
      end
      pin()
    end,
  })
  -- Fires: the editor resized under the dialog, which would leave it off centre or past the edge. Buffer-local, as
  -- the dialog's buffer is current for as long as it is open.
  vim.api.nvim_create_autocmd("VimResized", {
    buffer = buf,
    desc = "changeset: fit and centre a dialog in the resized editor",
    callback = function()
      vim.api.nvim_win_set_config(state.win, place(width, #lines))
    end,
  })
  return state
end

---Maps `lhs` in the dialog's buffer.
---@param state changeset.DialogState
---@param lhs string[]
---@param rhs fun()
---@param desc string
local function map(state, lhs, rhs, desc)
  for _, key in ipairs(lhs) do
    vim.keymap.set("n", key, rhs, { buffer = state.buf, nowait = true, desc = desc })
  end
end

---A row of pills, one per label, the last drawn as destructive and the focused one lit; and the byte range each
---takes on the line, for a click.
---@param labels string[]
---@param focus integer
---@return changeset.DialogLine chunks
---@return [integer, integer][] ranges
local function buttons(labels, focus)
  local chunks, ranges, col = {}, {}, 0
  for i, label in ipairs(labels) do
    if i > 1 then
      chunks[#chunks + 1] = { "  " }
      col = col + 2
    end
    local danger = i == #labels
    local hl = danger and (i == focus and highlights.BUTTON_DANGER_FOCUS_HL or highlights.BUTTON_DANGER_HL)
      or (i == focus and highlights.BUTTON_FOCUS_HL or highlights.BUTTON_HL)
    vim.list_extend(chunks, {
      { "  ", hl },
      { label:sub(1, 1), { hl, highlights.BUTTON_KEY_HL } },
      { label:sub(2) .. "  ", hl },
    })
    ranges[i] = { col, col + #label + 4 }
    col = col + #label + 4
  end
  return chunks, ranges
end

---Asks before a destructive action, calling `yes` only once its button is pressed. Focus starts on Keep, so a
---<CR> typed ahead declines; leaving the window any other way declines too. `yes` runs scheduled, once the dialog
---has closed and focus is back on the window it opened from.
---@param opts changeset.ConfirmOpts
---@param yes fun()
function M.confirm(opts, yes)
  local labels = { SAFE, opts.action }
  local body = M._body(opts.body, math.min(MEASURE, room(PAD)))
  local row, ranges = buttons(labels, 1)
  local width = cells.chunks(row)
  for _, line in ipairs(body) do
    width = math.max(width, cells.chunks(line))
  end
  local margin = { (" "):rep(PAD) }
  local indent = { (" "):rep(PAD + width - ranges[#ranges][2]) }

  ---@param focus integer
  ---@return changeset.DialogLine[]
  local function lines(focus)
    local out = { {} }
    for _, line in ipairs(body) do
      out[#out + 1] = vim.list_extend({ margin }, line)
    end
    out[#out + 1] = {}
    out[#out + 1] = vim.list_extend({ indent }, (buttons(labels, focus)))
    out[#out + 1] = {}
    return out
  end

  local focus = 1
  local state = open(lines(focus), { title = opts.title, width = width + 2 * PAD }, function(ok)
    if ok then
      yes()
    end
  end)
  if not state then
    return
  end
  local buttons_line = #body + 3

  ---@param to integer
  local function move(to)
    focus = to
    paint(state.buf, lines(focus))
    vim.api.nvim_win_set_cursor(state.win, { buttons_line, #indent[1] + ranges[focus][1] + 2 })
  end
  ---@param i integer
  local function press(i)
    finish(state, i == #labels)
  end
  move(focus)

  map(state, { "<Tab>" }, function()
    move(focus % #labels + 1)
  end, "Focus the next button")
  map(state, { "<S-Tab>" }, function()
    move((focus - 2) % #labels + 1)
  end, "Focus the previous button")
  map(state, { "h", "<Left>" }, function()
    move(math.max(focus - 1, 1))
  end, "Focus the button to the left")
  map(state, { "l", "<Right>" }, function()
    move(math.min(focus + 1, #labels))
  end, "Focus the button to the right")
  map(state, { "<CR>", "<Space>" }, function()
    press(focus)
  end, "Press the focused button")
  for i, label in ipairs(labels) do
    local letter = label:sub(1, 1)
    if i == #labels then
      -- The action takes Shift. Its letter without, as in Vim's `dd` with the second `d` typed ahead of the
      -- dialog, presses nothing, and quietly: unmapped, the read-only buffer would answer it with E21.
      map(state, { letter:lower() }, function() end, ("Nothing: %s takes %s"):format(label, letter:upper()))
    end
    map(state, { i == #labels and letter:upper() or letter:lower() }, function()
      press(i)
    end, label)
  end
  map(state, { "q", "<Esc>" }, function()
    press(1)
  end, SAFE)
  map(state, { "<LeftRelease>" }, function()
    local pos = vim.fn.getmousepos()
    if pos.winid ~= state.win or pos.line ~= buttons_line then
      return
    end
    local col = pos.column - 1 - #indent[1]
    for i, range in ipairs(ranges) do
      if col >= range[1] and col < range[2] then
        return press(i)
      end
    end
  end, "Press the button clicked")
end

---What `item` shows after its number and icon: its cells, or its cells dimmed and why it can't be chosen.
---@param item changeset.DialogItem
---@return changeset.DialogChunk[]
local function shown(item)
  if not item.unavailable then
    return item.cells
  end
  local out = vim.tbl_map(function(cell)
    return { cell[1], "Comment" }
  end, item.cells)
  out[#out + 1] = { item.unavailable, highlights.META_HL }
  return out
end

---Each item's row: its number, icon and cells, the columns lined up, and a blank cell for the focus bar.
---@param items changeset.DialogItem[]
---@return changeset.DialogLine[]
function M._rows(items)
  local widths = {}
  for _, item in ipairs(items) do
    local row = shown(item)
    for c = 1, #row - 1 do
      widths[c] = math.max(widths[c] or 0, cells.width(row[c][1]))
    end
  end
  local lines = {}
  for i, item in ipairs(items) do
    local number = i <= NUMBERED and tostring(i) or " "
    local line = { { "  " }, { number, item.unavailable and "Comment" or nil }, { "  " } }
    if item.icon then
      vim.list_extend(line, { item.icon, { " " } })
    end
    local row = shown(item)
    for c, cell in ipairs(row) do
      line[#line + 1] = cell
      if c < #row then
        line[#line + 1] = { (" "):rep(widths[c] - cells.width(cell[1]) + 2) }
      end
    end
    lines[i] = line
  end
  return lines
end

---`line` cut to `width` cells, the cut marked with "…".
---@param line changeset.DialogLine
---@param width integer
---@return changeset.DialogLine
function M._clip(line, width)
  if cells.chunks(line) <= width then
    return line
  end
  local out, left = {}, width - cells.width(cells.ELLIPSIS)
  for _, chunk in ipairs(line) do
    if cells.width(chunk[1]) > left then
      out[#out + 1] = { cells.head(chunk[1], left) .. cells.ELLIPSIS, chunk[2] }
      return out
    end
    out[#out + 1] = chunk
    left = left - cells.width(chunk[1])
  end
  return out
end

---Asks which of `opts.items` to act on, calling back with its index, or with nil once cancelled. An unavailable
---item is shown but can't be chosen. `cb` runs scheduled, once the dialog has closed and focus is back on the window
---it opened from.
---@param opts changeset.ChooseOpts
---@param cb fun(index: integer?)
function M.choose(opts, cb)
  local rows = vim.tbl_map(function(row)
    return M._clip(row, vim.o.columns - 4)
  end, M._rows(opts.items))
  local width = 0
  for _, row in ipairs(rows) do
    width = math.max(width, cells.chunks(row) + 2)
  end
  local digits = #opts.items == 1 and "1" or ("1-%d"):format(math.min(#opts.items, NUMBERED))

  ---@param focus integer?
  ---@return changeset.DialogLine[]
  local function lines(focus)
    return vim.tbl_map(function(i)
      local row = vim.list_slice(rows[i])
      if i == focus then
        row[1] = { BAR .. " ", highlights.SELECTED_ICON_HL }
      end
      return row
    end, vim.fn.range(1, #rows))
  end

  local focus = opts.focus
  if focus == nil then
    focus = vim.iter(ipairs(opts.items)):find(function(_, item)
      return not item.unavailable
    end)
  end
  focus = focus or nil
  local state = open(lines(focus), {
    title = opts.title,
    footer = ("<CR> or %s %s  q cancel"):format(digits, opts.action),
    width = width,
  }, cb)
  if not state then
    return
  end

  ---@param to integer?
  local function move(to)
    focus = to
    paint(state.buf, lines(focus), focus)
    if focus then
      vim.api.nvim_win_set_cursor(state.win, { focus, #BAR + 1 })
    end
  end
  ---@param i integer?
  local function choose(i)
    if i and opts.items[i] and not opts.items[i].unavailable then
      finish(state, i)
    end
  end
  ---@param by integer 1 for the next row that can be chosen, -1 for the previous.
  local function step(by)
    for i = (focus or by > 0 and 0 or #opts.items + 1) + by, by > 0 and #opts.items or 1, by do
      if not opts.items[i].unavailable then
        return move(i)
      end
    end
  end
  move(focus)

  map(state, { "j", "<Down>" }, function()
    step(1)
  end, "Focus the next row")
  map(state, { "k", "<Up>" }, function()
    step(-1)
  end, "Focus the previous row")
  map(state, { "<CR>" }, function()
    choose(focus)
  end, "Choose the focused row")
  for i = 1, math.min(#opts.items, NUMBERED) do
    map(state, { tostring(i) }, function()
      choose(i)
    end, ("Choose row %d"):format(i))
  end
  map(state, { "q", "<Esc>" }, function()
    finish(state, nil)
  end, "Cancel")
  map(state, { "<LeftRelease>" }, function()
    local pos = vim.fn.getmousepos()
    if pos.winid == state.win then
      choose(pos.line)
    end
  end, "Choose the row clicked")
end

return M
