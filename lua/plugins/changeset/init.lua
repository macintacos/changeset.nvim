---A read-only sidebar mapping what this branch changed, nested by symbol.
---
---See README.md for the design. This file is the glue: it gathers the diff and
---the symbols, hands them to `tree` and `render`, and owns the tree's lifecycle
---and the window state machine. The thinking happens in the pure modules it calls.

local Git = require("helpers.git")
local Paths = require("helpers.paths")
local cache = require("plugins.changeset.cache")
local help = require("plugins.changeset.help")
local prefs = require("plugins.changeset.prefs")
local render = require("plugins.changeset.render")
local resolve = require("plugins.changeset.resolve")
local sections = require("plugins.changeset.sections")
local state = require("plugins.changeset.state")
local tree = require("plugins.changeset.tree")
local view = require("plugins.changeset.view")
local window = require("plugins.changeset.window")

-- `:wall` writes every buffer, and regaining focus reloads every file changed
-- meanwhile. One rebuild per burst is enough, and a rebuild mid-keypress is what
-- the identity re-anchoring exists to survive.
local REFRESH_DEBOUNCE_MS = 250

-- How long a picker's first ask blocks on the diff before giving up on it.
local DIFF_WAIT_MS = 2000

-- input() reads a line, so it can never hand one back: free to mean "cancelled".
local CANCELLED = "\r"

-- One write per burst of answers rather than one per file.
local SAVE_DEBOUNCE_MS = 1000

-- Not <C-n>/<C-p>: plugin/multicursor.lua owns those, and shadowing them would mean
-- deleting a user mapping on close. `h` is free across mini.bracketed's targets.
-- Next first — the bindings and `?` both index this order.
local STEP_KEYS = { "]h", "[h" }

-- Capitalised: `:mksession` saves only globals named so, and only with "globals" in 'sessionoptions'.
local POSITION_GLOBAL = "ChangesetPosition"

-- The totals row over the tree and the blank one under it.
local HEADER_LINES = 2

local M = {}

local ns = vim.api.nvim_create_namespace("changeset")
-- Separate from `ns` so the tracker can repaint row backgrounds without redrawing the tree.
local rows_ns = vim.api.nvim_create_namespace("changeset.rows")
local augroup = vim.api.nvim_create_augroup("changeset", { clear = true })

---@class changeset.Landing
---@field id string? nil when it landed before the tree had rows; the table's presence is what marks a landing pending.

---@class changeset.Session
---@field root string
---@field base string
---@field ref string Ref the fork point was measured against, e.g. "origin/trunk".
---@field branch string
---@field file string Preferences file for this changeset session.
---@field default_branch string
---@field pr integer? The branch's open PR, while the tree is measured against its target.
---@field files changeset.File[]
---@field commits integer? Commits on the branch since `base`, once the diff has been read.
---@field collected boolean Whether the diff has been read yet.
---@field symbols table<string, changeset.CachedSymbol[]> Absent key means "still resolving".
---@field rows changeset.Row[]
---@field visible changeset.Row[]
---@field st changeset.State
---@field query string
---@field hidden table<string, true> Symbol kinds the tree is not showing.
---@field cancel fun()?
---@field timer uv.uv_timer_t?
---@field request table? The refresh whose answers this session is still listening for.
---@field here changeset.Spot? Where the cursor is, while that is a file in this repository.
---@field landing changeset.Landing? The row focusing the sidebar put its cursor on, until the user moves it.
---@field restoring changeset.Position? A restored session's position, until the tree can hold each half.

---What a session saved of where you were: the file you were in and the sidebar's cursor row.
---@class changeset.Position
---@field here changeset.Spot? The file and line you were in.
---@field row { id: string, path: string }? The row the sidebar's cursor was on.
---@field at string? Id of the row under the sidebar's cursor when last checked; another means the user moved it.

---@type changeset.Session?
local session

---Symbols read for the repo at `root`, carried between builds and to disk.
---@type { root: string, entries: table<string, changeset.CacheEntry> }?
local memo

---@type uv.uv_timer_t?
local save_timer

---Whether a `track` is already scheduled for this tick.
---@type boolean
local tracking = false

---Folds outlive the tree: a rebuild for a moved fork point, or a trip to another
---repository and back, keeps them. Kept per repository: row ids are built from
---repo-relative paths, so one table would share a fold between two checkouts that
---both have a `lua/config/options.lua`.
---@type table<string, changeset.State>
local folds = {}

---Each open PR's target and number, by repository and branch; false while gh is asked.
---No answer is not kept, so a PR opened later is found on the next build.
---@type table<string, { target: string, number: integer }|false>
local targets = {}

---Whether the window last left was a float: coming back from one is not arriving.
---@type boolean
local left_float = false

---Stop a deferred callback for good. `vim.defer_fn` closes its handle from inside the
---callback, so a timer replaced before it fires leaves one open.
---@param timer uv.uv_timer_t?
local function stop(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

local function save_soon()
  stop(save_timer)
  save_timer = vim.defer_fn(function()
    if memo then
      cache.save(cache.path(memo.root), memo.entries)
    end
  end, SAVE_DEBOUNCE_MS)
end

---@param category string MiniIcons category.
---@param name string
---@return string glyph, string hl
local function icon(category, name)
  -- The call is wrapped, not `MiniIcons.get`: an argument is evaluated before `pcall`
  -- runs, so indexing a missing mini.icons would raise past the fallback below.
  local ok, glyph, hl = pcall(function()
    return MiniIcons.get(category, name)
  end)
  if ok then
    return glyph, hl
  end
  return " ", "Normal"
end

---@param row changeset.Row
---@return string glyph, string hl
local function icon_for(row)
  if row.kind == "section" then
    return icon("directory", row.icon)
  end
  if row.kind == "file" then
    return icon("file", row.path)
  end
  return icon("lsp", row.kind == "symbol" and row.symbol_kind or "Text")
end

---@return changeset.Row?
local function row_at_cursor()
  if not session then
    return nil
  end
  local win = window.win()
  if not win then
    return nil
  end
  return session.visible[vim.api.nvim_win_get_cursor(win)[1]]
end

---Whether the file at `path` holds edits the file on disk does not.
---@param path string Absolute.
---@return boolean
local function unwritten(path)
  local buf = vim.fn.bufnr(path)
  return buf ~= -1 and vim.bo[buf].modified
end

---@param row changeset.Row
---@return changeset.Band
local function band_for(row)
  local glyph, hl = icon("file", row.path)
  return {
    icon = glyph,
    icon_hl = render.band_icon(hl),
    path = row.path,
    -- Only a symbol row names its destination. An orphan hunk's own text is the
    -- changed line, which is not a place and does not read as one.
    destination = row.kind == "symbol" and row.name or nil,
  }
end

local function preview_current()
  local row = row_at_cursor()
  if not row then
    return
  end
  assert(session, "changeset: no open session")
  if row.lnum and row.kind ~= "file" then
    window.preview(session.root .. "/" .. row.path, row.lnum, band_for(row))
  elseif row.kind == "file" and row.status == "deleted" then
    window.preview_notice("This file was deleted on this branch", band_for(row))
  elseif row.kind == "file" then
    window.preview(session.root .. "/" .. row.path, 1, band_for(row))
  end
end

---@return string[] ids Of the rows on screen, in display order.
local function visible_ids()
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
---and the row for where you are, or its nearest ancestor on screen. A row both
---would mark shows the selection.
local function paint()
  local buf, win = window.buf(), window.win()
  if not (session and buf and win) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, rows_ns, 0, -1)
  local width = vim.api.nvim_win_get_width(win)
  local selected = window.is_focused() and row_at_cursor() and vim.api.nvim_win_get_cursor(win)[1]
  local here = session.here and tree.locate(session.rows, session.here.path, session.here.lnum)
  local here_lnum = here and state._nearest(visible_ids(), here.id)
  if here_lnum and here_lnum ~= selected then
    mark_row(buf, here_lnum, render.state_marks("here", width))
  end
  if selected then
    mark_row(buf, selected, render.state_marks("selected", width))
  end
end

local PASSING_BUFTYPES = { terminal = true, help = true }

---Stop waiting to restore one half of a session's position.
---@param half "here"|"row"
local function release(half)
  assert(session, "changeset: no open session")
  local wanted = session.restoring
  if wanted then
    wanted[half] = nil
    if not (wanted.here or wanted.row) then
      session.restoring = nil
    end
  end
end

---Note the file and line the cursor is in. The sidebar, floats, terminals and help
---are not somewhere the user is, so they leave the last place standing.
local function track()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  if
    not session
    or win == window.win()
    or vim.api.nvim_win_get_config(win).relative ~= ""
    or PASSING_BUFTYPES[vim.bo[buf].buftype]
  then
    return
  end
  local name = vim.api.nvim_buf_get_name(buf)
  local path = name ~= "" and vim.fs.relpath(session.root, vim.fs.normalize(name)) or nil
  session.here = path and { path = path, lnum = vim.api.nvim_win_get_cursor(win)[1] } or nil
  release("here")
  paint()
end

---Keep where you are and the sidebar's cursor row in a global `:mksession` saves, so
---every session write carries them without work of its own at write time.
local function remember()
  -- Not while a restored position waits: a write then would save the half-built tree's.
  if session and not session.restoring then
    local row = row_at_cursor()
    vim.g[POSITION_GLOBAL] = vim.json.encode({ here = session.here, row = row and { id = row.id, path = row.path } })
  end
end

---Put the sidebar's cursor on "you are here", or its nearest ancestor on screen,
---and note where it landed.
---@param win integer The sidebar's window.
local function land(win)
  assert(session, "changeset: no open session")
  local here = session.here
  local row = here and tree.locate(session.rows, here.path, here.lnum)
  local lnum = row and state._nearest(visible_ids(), row.id)
  if lnum then
    vim.api.nvim_win_set_cursor(win, { lnum, 0 })
  end
  session.landing = { id = (row_at_cursor() or {}).id }
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
---@param width integer Sidebar width; the note gets one cell less, for its leading space.
---@param hidden_kinds table Kinds being hidden, as `view.hiding` reports them.
local function hidden_note_line(buf, anchor_line, width, hidden_kinds)
  local note = render.hidden_note(hidden_kinds, width - 1)
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
local function reveal_header(win)
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
  reveal_header(win)
end

local function draw()
  local buf, win = window.buf(), window.win()
  if not (buf and win and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  assert(session, "changeset: no open session")

  local previous_row = row_at_cursor()
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
  hidden_note_line(buf, #text - 1, width, view.hiding(view.kind_counts(session.rows), session.hidden))

  vim.api.nvim_win_set_cursor(win, { state._reanchor(session.visible, previous_row, previous_line), 0 })

  draw_header(buf, win, width)
  paint()
end

---Text of a changed line, for captioning an orphan hunk.
---
---Prefers the buffer, which holds unwritten changes the file does not. Reading
---symbols is what loads a file, so a file answered from the cache has no buffer
---and is read from disk instead.
---@param path string
---@param lnum integer
---@return string?
local function line_text(path, lnum)
  if lnum < 1 then
    return nil
  end
  assert(session, "changeset: no open session")
  local full = session.root .. "/" .. path
  local buf = vim.fn.bufnr(full)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    return vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1]
  end
  local ok, lines = pcall(vim.fn.readfile, full, "", lnum)
  return ok and lines[lnum] or nil
end

---Whether the tree is done growing under `path`: its diff is in, and so are its
---symbols unless the diff does not hold it.
---@param path string
---@return boolean
local function decided(path)
  assert(session, "changeset: no open session")
  if not session.collected then
    return false
  end
  -- A deleted file's symbols are never read.
  return session.symbols[path] ~= nil
    or not vim.iter(session.files):any(function(file)
      return file.path == path and file.status ~= "deleted"
    end)
end

---Apply each half of a restored position once its file is decided, and drop a half
---the tree no longer holds.
local function apply_restored()
  assert(session, "changeset: no open session")
  local wanted = session.restoring
  if wanted and wanted.here and decided(wanted.here.path) then
    if tree.locate(session.rows, wanted.here.path, wanted.here.lnum) then
      session.here = wanted.here
      paint()
    end
    release("here")
  end
  if wanted and wanted.row and decided(wanted.row.path) then
    local win = window.win()
    local lnum = win and tree.find(session.rows, wanted.row.id) and state._nearest(visible_ids(), wanted.row.id)
    if win and lnum then
      vim.api.nvim_win_set_cursor(win, { lnum, 0 })
      -- Else a pending landing's follow would pull the cursor back off it.
      session.landing = nil
    end
    release("row")
  end
end

local function rebuild()
  assert(session, "changeset: no open session")
  -- Taken before the rows change. Before the first diff the landing and the row under
  -- the cursor are both nil, which is still "not moved". Only a rebuild follows: a
  -- fold or filter redraw brings no deeper row.
  local at = (row_at_cursor() or {}).id
  local follow = session.landing and window.is_focused() and session.landing.id == at
  -- The same "until the user moves it" rule holds a restored row.
  if session.restoring and window.is_focused() and session.restoring.at ~= at then
    release("row")
  end
  session.rows = tree.build(session.files, session.symbols, line_text)
  draw()
  if follow then
    land(vim.api.nvim_get_current_win())
  else
    session.landing = nil
  end
  -- After the landing: a restored row overrides it.
  apply_restored()
  if session.restoring then
    session.restoring.at = (row_at_cursor() or {}).id
  end
end

---@param row changeset.Row
---@param open boolean
local function set_open(row, open)
  assert(session, "changeset: no open session")
  -- A compressed chain hides intermediate rows; a folded row hides its children.
  -- `l` on a compressed row means the first, so it wins while the chain is shut.
  if row.chain and not state.is_chain_open(session.st, row.id) and open then
    state.set_chain_open(session.st, row.id, true)
  elseif row.chain and state.is_chain_open(session.st, row.id) and not open then
    state.set_chain_open(session.st, row.id, false)
  else
    state.set_collapsed(session.st, row.id, not open)
  end
  draw()
end

---@param how "reuse"|"vsplit"|"split"|"tab"
local function commit(how)
  local row = row_at_cursor()
  if not row or row.kind == "section" then
    return
  end
  if row.kind == "file" and row.status == "deleted" then
    return vim.notify(row.path .. " was deleted on this branch", vim.log.levels.INFO)
  end
  assert(session, "changeset: no open session")
  window.commit(session.root .. "/" .. row.path, row.lnum or 1, how)
end

---@param delta integer
local function step(delta)
  local win = window.win()
  if not (session and win) then
    return
  end
  local lnum = state._step(session.visible, vim.api.nvim_win_get_cursor(win)[1], delta)
  vim.api.nvim_win_set_cursor(win, { lnum, 0 })
  preview_current()
end

---Open the symbol-kind filter menu, redrawing as kinds are toggled.
---@param open_session changeset.Session
local function open_kind_menu(open_session)
  require("plugins.changeset.menu").open({
    root = open_session.root,
    branch = open_session.branch,
    file = open_session.file,
    counts = view.kind_counts(open_session.rows),
    hidden = open_session.hidden,
    icon = function(symbol_kind)
      return icon("lsp", symbol_kind)
    end,
    sidebar = assert(window.win(), "changeset: sidebar is closed"),
    on_change = function(hidden)
      open_session.hidden = hidden
      draw()
    end,
  })
end

---Narrow the tree from the command line, restoring the previous query on cancel.
---@param open_session changeset.Session
local function prompt_filter(open_session)
  local previous_query = open_session.query
  local group = vim.api.nvim_create_augroup("changeset.filter", { clear = true })
  -- input() edits on the command line, so every keystroke is a CmdlineChanged
  -- — which is what lets the tree narrow as it is typed rather than at <CR>.
  vim.api.nvim_create_autocmd("CmdlineChanged", {
    group = group,
    desc = "changeset: filter the tree on each keystroke of the filter prompt",
    callback = function()
      open_session.query = vim.fn.getcmdline()
      draw()
      vim.cmd("redraw")
    end,
  })

  local ok, typed = pcall(vim.fn.input, {
    prompt = "Filter changes: ",
    default = previous_query,
    cancelreturn = CANCELLED,
  })
  vim.api.nvim_del_augroup_by_id(group)

  open_session.query = (ok and typed ~= CANCELLED) and typed or previous_query
  draw()
end

---Put the cursor on the nearest section header in `delta`'s direction, if there is one.
---@param open_session changeset.Session
---@param delta integer 1 or -1.
local function to_section(open_session, delta)
  local win = window.win()
  if not win then
    return
  end
  local lnum = state._section(open_session.visible, vim.api.nvim_win_get_cursor(win)[1], delta)
  vim.api.nvim_win_set_cursor(win, { lnum, 0 })
end

---What `h` does from a row: shut it, or put the cursor on its parent.
---@param open_session changeset.Session
local function collapse_or_parent(open_session)
  local row, win = row_at_cursor(), window.win()
  if not (row and win) then
    return
  end
  local action, parent_lnum = state._outward(open_session.visible, vim.api.nvim_win_get_cursor(win)[1])
  if action == "collapse" then
    set_open(row, false)
  elseif action == "parent" then
    vim.api.nvim_win_set_cursor(win, { parent_lnum, 0 })
  end
end

---@param open_session changeset.Session
local function collapse_all_files(open_session)
  state.collapse_all(
    open_session.st,
    vim.tbl_map(function(row)
      return row.id
    end, tree.files(open_session.rows))
  )
  draw()
end

---Keeps every section's fold, including one whose section is empty for now.
---@param open_session changeset.Session
local function expand_all_files(open_session)
  state.expand_all(open_session.st, tree.section_ids())
  draw()
end

---@param buf integer
local function set_keymaps(buf)
  local set, own = help.mapper(buf)
  -- The window can outlive the session: a `build()` for another repository lets go
  -- of the tree while a sidebar stands. Handing the session down rather than letting
  -- handlers reach for it means the check that it exists is the same line that
  -- passes it on.
  ---@param lhs string
  ---@param fn fun(open_session: changeset.Session)
  ---@param desc string
  local function map(lhs, fn, desc)
    set(lhs, function()
      if session then
        fn(session)
      end
    end, desc)
  end

  map("<CR>", function()
    commit("reuse")
  end, "Go to this change")
  -- The commit leaves the cursor in the window it jumped to, and `close` keeps
  -- focus where it already is, so the sidebar goes without taking the jump back.
  map("<S-CR>", function()
    commit("reuse")
    M.close()
  end, "Go to this change and close the tree")
  map("/", function()
    commit("vsplit")
  end, "Go to this change in a vertical split")
  map("-", function()
    commit("split")
  end, "Go to this change in a split")
  map("<C-t>", function()
    commit("tab")
  end, "Go to this change in a new tab")
  map("q", M.close, "Close the tree")
  map("l", function()
    local row = row_at_cursor()
    if row then
      set_open(row, true)
    end
  end, "Expand")
  map("h", collapse_or_parent, "Collapse, or step out to the parent")
  map("H", collapse_all_files, "Collapse every file")
  map("L", expand_all_files, "Expand every file")
  map("]]", function(open_session)
    to_section(open_session, 1)
  end, "Next section")
  map("[[", function(open_session)
    to_section(open_session, -1)
  end, "Previous section")
  map("R", M.refresh, "Rebuild the tree")
  map("y", function()
    local row = row_at_cursor()
    if row and row.kind ~= "section" then
      Paths.copy(row.lnum and ("%s:%d"):format(row.path, row.lnum) or row.path, "relative path:line")
    end
  end, "Yank path:line")
  map("?", function()
    help.show(buf, own, STEP_KEYS)
  end, "Show these keymaps")
  map("F", open_kind_menu, "Filter by symbol kind")
  map("f", prompt_filter, "Filter the tree")
end

---The Generated files, each filed as answered with no symbols, and the rest, which a server is asked about.
---@param files changeset.File[]
---@return table<string, changeset.CachedSymbol[]> generated_symbols Each Generated path mapped to `{}`.
---@return changeset.File[] readable The other files, in order.
local function split_generated(files)
  local generated_symbols, readable = {}, {}
  for _, file in ipairs(files) do
    if sections.classify(file.path, file.generated) == "generated" then
      generated_symbols[file.path] = {}
    else
      readable[#readable + 1] = file
    end
  end
  return generated_symbols, readable
end

---File what a server said about `path` in the symbol cache, while the cache is still `root`'s.
---@param root string
---@param path string Repo-relative.
---@param items MiniPickers.Symbol[]? nil when no server answered.
---@param stamp string? The file as it stood when its symbols were asked for.
local function file_answer(root, path, items, stamp)
  if not (memo and memo.root == root and stamp) then
    return
  end
  -- Only an answer that arrived is filed. A server that never attached would
  -- otherwise leave "this file has no symbols" on disk, fresh until the file
  -- next moves; and a stamp taken off the file cannot describe what a server
  -- read out of a buffer holding unwritten edits.
  if items and not unwritten(root .. "/" .. path) then
    memo.entries[path] = { stamp = stamp, symbols = cache.project(items) }
    save_soon()
  elseif not items then
    -- Not asked again on every refresh — each ask waits out the attach timeout
    -- under a "reading symbols" row — only once the file moves or a server
    -- arrives for it.
    memo.entries[path] = { stamp = stamp, symbols = {}, silent = true }
  end
end

---Gather the diff, then let symbols fill in behind it.
function M.refresh()
  if not session then
    return
  end
  if session.cancel then
    session.cancel()
    session.cancel = nil
  end

  -- Identity rather than a counter: an answer from a refresh that this one replaced
  -- has to be dropped, and a session built later starts from a table of its own.
  local request = {}
  session.request = request

  local diff = require("plugins.changeset.diff")
  diff.collect(session.base, session.root, function(files, err, commits)
    if not session or session.request ~= request then
      return
    end
    if not files then
      -- Nothing would ever settle it, and it silences `remember`.
      session.restoring = nil
      return vim.notify("Changeset: " .. (err or "git failed"), vim.log.levels.ERROR)
    end
    session.files = files
    session.commits = commits
    session.collected = true
    -- Generated files are never asked about; filed as answered with nothing, they
    -- show no placeholder and count as read.
    local generated_symbols, readable = split_generated(files)

    -- Stamped before the request rather than after: a file edited while its
    -- symbols are being read then fails this check next time, instead of
    -- leaving behind an answer for content that has already moved on.
    assert(memo, "changeset: symbol cache not loaded")
    local stamps = {}
    local known, unknown = cache.fresh(memo.entries, readable, function(path)
      assert(session, "changeset: no open session")
      stamps[path] = cache.stamp(session.root .. "/" .. path)
      return stamps[path]
    end)
    session.symbols = vim.tbl_extend("force", known, generated_symbols)

    -- Down to what this diff needs: the file caches the branch being read, not
    -- every file whose symbols have ever been asked for.
    local entries = memo.entries
    memo.entries = {}
    for path in pairs(known) do
      memo.entries[path] = entries[path]
    end
    rebuild()

    local root = session.root
    session.cancel = resolve.start(root, unknown, function(path, items)
      -- Filed even once a newer refresh has replaced this one: the stamp predates
      -- the request, so the answer still describes the file it was read from.
      file_answer(root, path, items, stamps[path])
      if session and session.request == request then
        -- A server that answers nothing is "resolved with no symbols", which is what
        -- turns every hunk in an unsupported file into an orphan row. Leaving the key
        -- absent would instead read as "still resolving", forever.
        session.symbols[path] = items or {}
        rebuild()
      end
    end)
  end)
end

---Let go of the tree, stopping whatever it was still gathering.
local function drop()
  if session then
    if session.cancel then
      session.cancel()
    end
    stop(session.timer)
  end
  session = nil
end

---The branch `branch`'s open PR, once gh has said. Asks it otherwise, and builds
---again when the answer lands on the repository and branch still in view.
---@param root string
---@param branch string
---@return { target: string, number: integer }?
local function pr_target(root, branch)
  local key = root .. "\n" .. branch
  if targets[key] == nil then
    targets[key] = false
    Git.pr_target(root, function(target, number)
      targets[key] = target and { target = target, number = number } or nil
      if target and session and session.root == root and session.branch == branch and Paths.root(0) == root then
        local kept = session
        M.build()
        -- A PR onto the branch already compared against leaves the tree standing,
        -- and only the header has news.
        if session == kept then
          draw()
        end
      end
    end)
  end
  return targets[key] or nil
end

---Build the tree for the current buffer's repository, unless it is already built there.
---
---The buffer's repository, not Neovim's directory: with the two different, a base
---measured in the wrong one leaves every later `git diff` on a bad object.
---@return boolean ready false when the repository has no merge base with its default
---branch, which includes a buffer outside any repository.
function M.build()
  local root = Paths.root(0)
  local base, _, ref = Git.merge_base(root)
  if not base then
    return false
  end
  local branch = Git.lines({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, root)[1] or "HEAD"
  -- A stacked branch reads its fork point from its PR's target; one that target
  -- has none with (never fetched, say) stays on the default branch's.
  local pr, number = pr_target(root, branch), nil
  if pr then
    local stacked, _, stacked_ref = Git.merge_base(root, pr.target)
    if stacked then
      -- Named only while the tree is measured against the ref the PR merges into.
      base, ref, number = stacked, stacked_ref, pr.number
    end
  end
  if session and session.root == root and session.base == base and session.branch == branch then
    session.pr = number
    return true
  end
  drop()

  if not memo or memo.root ~= root then
    memo = { root = root, entries = cache.load(cache.path(root)) }
  end

  if not folds[root] then
    folds[root] = state.new()
    -- Only on creation, so an unfold is kept like any other fold.
    state.set_collapsed(folds[root], tree.section_id("generated"), true)
  end
  local preferences_file = prefs.path()
  local default_branch = Git.default_base(root)
  session = {
    root = root,
    base = base,
    ref = ref or default_branch,
    branch = branch,
    file = preferences_file,
    default_branch = default_branch,
    pr = number,
    files = {},
    collected = false,
    symbols = {},
    rows = {},
    visible = {},
    st = folds[root],
    query = "",
    hidden = prefs.resolve(prefs.load(preferences_file), root, branch),
  }
  M.refresh()
  return true
end

---The sidebar's footer, which its statusline evaluates on every redraw.
---@return string
function M.footer()
  local win = window.win()
  if not (session and win) then
    return ""
  end
  local file, files = view.position(session.visible, vim.api.nvim_win_get_cursor(win)[1])
  return render.footer({ file = file, files = files, query = session.query })
end

---The file rows under the sidebar's sections, less the kinds it hides, for the current buffer's repository.
---@return { rows: changeset.Row[], root: string, ref: string }? tree
---@return string? err Why there is no tree yet.
function M.rows()
  if not M.build() then
    return nil, "no merge base with the default branch"
  end
  -- The first ask builds the tree too, and a picker cannot fill in behind it the way the sidebar does.
  vim.wait(DIFF_WAIT_MS, function()
    return not session or session.collected
  end, 10)
  if not (session and session.collected) then
    return nil, "still reading the diff"
  end
  return { rows = view.by_kind(tree.files(session.rows), session.hidden), root = session.root, ref = session.ref }
end

---The tree, for specs.
---@return changeset.Session?
function M._tree()
  return session
end

---Open the sidebar on the current buffer's repository, drawing its tree.
function M.open()
  -- `window.buf()`, not `window.win()`: the buffer is wiped with its window, so it is
  -- live exactly while a sidebar stands on some tabpage.
  if window.buf() then
    M.close()
  end
  local kept = session
  if not M.build() then
    return vim.notify("Changeset: no merge base with the default branch", vim.log.levels.WARN)
  end

  -- The cursor is still where the user was, and nothing tracked it before a tree existed.
  track()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "changeset"
  vim.bo[buf].buftype = "nofile"
  -- Wiped with its window. A scratch buffer is kept otherwise, so every close would
  -- leave one behind, its extmarks and mappings included.
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  -- The tree draws its own guides; a scope line would be a second set.
  vim.b[buf].miniindentscope_disable = true
  -- The hidden cursor rests on each row's rail, which would wear the word underline.
  vim.b[buf].minicursorword_disable = true

  render.define_highlights()
  local win = window.open(buf)
  vim.wo[win].statusline = "%{%v:lua.require'plugins.changeset'.footer()%}"
  -- After `filetype`, so these replace the `]]`/`[[` illuminate maps on every buffer at `FileType`.
  set_keymaps(buf)

  -- Fires: the sidebar's window going without the plugin being asked — `:q`, `:only`,
  -- `:tabclose`, a layout plugin. Scheduled because the window is still in the layout
  -- while this runs, and `close` reads the layout to decide where to leave the cursor.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    pattern = tostring(win),
    desc = "changeset: let go of the sidebar when its window closes another way",
    callback = function()
      vim.schedule(M.close)
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    buffer = buf,
    desc = "changeset: preview the row under the cursor without leaving the sidebar",
    callback = preview_current,
  })
  -- Fires: the sidebar's cursor moving. The selected row is the cursor's own marker,
  -- the terminal's being hidden here, so it moves in step rather than a tick behind.
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    buffer = buf,
    desc = "changeset: move the selected row with the cursor",
    callback = function()
      paint()
    end,
  })
  -- Fires: the sidebar scrolling, by any means. Back at the top, the header's totals
  -- stay out of view unless they are scrolled in again. Only on the way up: scrolling
  -- down from the top starts by taking them away, and restoring them would pin the tree.
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = augroup,
    pattern = tostring(win),
    desc = "changeset: keep the header's totals in view at the top of the tree",
    callback = function()
      if vim.v.event[tostring(win)].topline < 0 then
        reveal_header(win)
      end
    end,
  })
  -- Fires: the editor being resized. Moves the tree below the files when the editor
  -- gets too narrow to keep it beside them, and back once it is wide enough; redrawn
  -- either way, since rows are trimmed to the window's width.
  vim.api.nvim_create_autocmd("VimResized", {
    group = augroup,
    desc = "changeset: move the tree beside or below the files as the editor's width allows",
    callback = function()
      window.relayout()
      draw()
    end,
  })
  -- Fires: leaving any window while the sidebar is open. Remembers whether it was a
  -- float, so the sidebar's `WinEnter` can tell a return from one from an arrival.
  vim.api.nvim_create_autocmd("WinLeave", {
    group = augroup,
    desc = "changeset: note whether the window being left is a float",
    callback = function()
      left_float = vim.api.nvim_win_get_config(0).relative ~= ""
    end,
  })
  -- Fires: the cursor entering the sidebar by any route — `<leader>gp`, a click,
  -- `<C-w>` — but not a return from a float such as the kind menu, which the user
  -- never left the sidebar for. Lands on the row you are on, dropping a restored row
  -- still waiting; the `CursorMoved` that follows previews it.
  vim.api.nvim_create_autocmd("WinEnter", {
    group = augroup,
    buffer = buf,
    desc = "changeset: put the sidebar's cursor on the row you are on",
    callback = function()
      local current = vim.api.nvim_get_current_win()
      if session and current == window.win() and not left_float then
        release("row")
        land(current)
      end
    end,
  })
  -- Fires: the cursor entering any window while the sidebar is open. Nested so the
  -- buffer swaps inside the commit fire their autocmds as `<CR>`'s do.
  vim.api.nvim_create_autocmd("WinEnter", {
    group = augroup,
    nested = true,
    desc = "changeset: open a previewed file once the cursor enters its window",
    callback = window.claim,
  })
  -- Fires: the cursor entering any window while the sidebar is open, so the cursor
  -- hides and the selected row appears on arriving in the sidebar, and both undo on
  -- leaving it, for a float opened from it too.
  vim.api.nvim_create_autocmd("WinEnter", {
    group = augroup,
    desc = "changeset: stand the selected row in for the cursor while it is in the sidebar",
    callback = function()
      window.sync_cursor()
      paint()
    end,
  })
  vim.keymap.set("n", STEP_KEYS[1], function()
    step(1)
  end, { desc = "Next change (Changeset)" })
  vim.keymap.set("n", STEP_KEYS[2], function()
    step(-1)
  end, { desc = "Previous change (Changeset)" })

  draw()
  -- A kept tree misses what nothing announced, such as a file edited outside Neovim while it kept focus.
  if session == kept then
    M.refresh()
  end
end

---Dismiss the sidebar and the global `]h`/`[h` keys. The tree stays, and keeps refreshing.
function M.close()
  require("plugins.changeset.menu").close()
  for _, lhs in ipairs(STEP_KEYS) do
    pcall(vim.keymap.del, "n", lhs)
  end
  vim.api.nvim_clear_autocmds({ group = augroup })
  window.close()
end

---The position a session recorded, keeping only the parts shaped as `remember` writes them.
---@param value any The position global, as the session left it.
---@return changeset.Position?
local function recorded(value)
  local ok, position = pcall(vim.json.decode, value)
  if not ok or type(position) ~= "table" then
    return nil
  end
  local here, row = position.here, position.row
  here = type(here) == "table" and type(here.path) == "string" and type(here.lnum) == "number" and here or nil
  row = type(row) == "table" and type(row.id) == "string" and type(row.path) == "string" and row or nil
  return (here or row) and { here = here, row = row } or nil
end

---Fill the window a restored session left standing where the sidebar was, and bring
---back where you were and the sidebar's cursor row once the tree holds them.
---
---A session records the layout but not a scratch buffer's contents, so the
---sidebar comes back empty. Filling that window is also what keeps the next
---`<leader>gp` from opening a second one beside it.
function M.restore()
  local placeholder = window.placeholder()
  if not placeholder then
    return
  end
  M.open()
  if not window.is_visible() then
    vim.api.nvim_win_close(placeholder, true)
    return
  end
  assert(session, "changeset: no open session")
  session.restoring = recorded(vim.g[POSITION_GLOBAL])
  if session.restoring then
    session.restoring.at = (row_at_cursor() or {}).id
    apply_restored()
  end
end

---What `<leader>gp` does next, given where the sidebar and the cursor are.
---@param st { visible: boolean, focused: boolean }
---@return "open"|"focus"|"close"
function M._next_action(st)
  if not st.visible then
    return "open"
  end
  return st.focused and "close" or "focus"
end

---Open, focus, or dismiss the sidebar, depending on where the cursor is.
function M.toggle()
  local action = M._next_action({ visible = window.is_visible(), focused = window.is_focused() })
  if action == "open" then
    M.open()
    window.focus()
  elseif action == "focus" then
    window.focus()
  else
    M.close()
  end
end

-- The meta highlight is mixed from Comment's foreground, which a new colorscheme
-- replaces. Same idiom as lua/config/highlights.lua.
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("changeset.highlights", { clear = true }),
  desc = "changeset: rebuild the dim label colour against the new palette",
  callback = render.define_highlights,
})

-- Fires: every buffer or window switch and cursor move, sidebar open or not, so
-- "you are here" is current whenever the sidebar shows. Scheduled because a
-- preview swaps its buffer inside `nvim_win_call`, which fires these with the
-- borrowed window current; by the next tick focus is back where the user is.
vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "CursorMoved", "CursorMovedI" }, {
  group = vim.api.nvim_create_augroup("changeset.track", { clear = true }),
  desc = "changeset: track the file and line the cursor is in",
  callback = function()
    if session and not tracking then
      tracking = true
      vim.schedule(function()
        tracking = false
        track()
        remember()
      end)
    end
  end,
})

-- Fires: the cursor entering any window, or any window taking a buffer, sidebar
-- open or not — the two ways a preview band can come to sit where the user reads.
vim.api.nvim_create_autocmd({ "WinEnter", "BufWinEnter" }, {
  group = vim.api.nvim_create_augroup("changeset.unband", { clear = true }),
  desc = "changeset: keep the preview band off the window the cursor is in",
  callback = window.unband,
})

-- Fires: a language server attaching to any buffer. A file no server answered for
-- is not asked about again until it changes, so one that attaches late — started
-- slowly, or installed since — would otherwise never be heard from.
vim.api.nvim_create_autocmd("LspAttach", {
  group = vim.api.nvim_create_augroup("changeset.servers", { clear = true }),
  desc = "changeset: ask again about a file once a server that lists symbols reaches it",
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    if not (session and memo and client and client:supports_method("textDocument/documentSymbol")) then
      return
    end
    local path = vim.fs.relpath(session.root, vim.fs.normalize(vim.api.nvim_buf_get_name(args.buf)))
    local entry = path and memo.entries[path]
    if path and entry and entry.silent then
      memo.entries[path] = nil
      M.refresh()
    end
  end,
})

local function refresh_soon()
  if not session then
    return
  end
  stop(session.timer)
  session.timer = vim.defer_fn(function()
    if session then
      M.refresh()
    end
  end, REFRESH_DEBOUNCE_MS)
end

local watch = vim.api.nvim_create_augroup("changeset.watch", { clear = true })

-- Fires: a write, a buffer reloaded after its file changed outside Neovim, and Neovim
-- regaining focus — the moments the files git diffs from disk can have moved.
-- Nothing else does: the diff reads the disk, so unwritten edits never move it.
vim.api.nvim_create_autocmd({ "BufWritePost", "FileChangedShellPost", "FocusGained" }, {
  group = watch,
  desc = "changeset: rebuild the tree after the working tree changes",
  callback = refresh_soon,
})

-- Fires: gitsigns seeing HEAD move, a checkout or rebase made anywhere, which it
-- publishes without a buffer. The per-buffer ones fire on every attach and every
-- hunk change while typing, and the symbol walk's own loads would restart it.
vim.api.nvim_create_autocmd("User", {
  pattern = "GitSignsUpdate",
  group = watch,
  desc = "changeset: rebuild the tree after the branch changes",
  callback = function(args)
    if not (args.data and args.data.buffer) then
      refresh_soon()
    end
  end,
})

return M
