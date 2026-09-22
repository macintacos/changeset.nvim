---A read-only sidebar mapping what this branch changed, nested by symbol.
---
---See README.md for the design. This file is the glue: it gathers the diff and
---the symbols, hands them to `tree` and `render`, and owns the window state
---machine. The thinking happens in the pure modules it calls.

local Git = require("helpers.git")
local Paths = require("helpers.paths")
local cache = require("plugins.changeset.cache")
local help = require("plugins.changeset.help")
local prefs = require("plugins.changeset.prefs")
local render = require("plugins.changeset.render")
local resolve = require("plugins.changeset.resolve")
local state = require("plugins.changeset.state")
local tree = require("plugins.changeset.tree")
local view = require("plugins.changeset.view")
local window = require("plugins.changeset.window")

-- gitsigns republishes on every sign refresh, several times per write. One
-- rebuild per burst is enough, and a rebuild mid-keypress is what the identity
-- re-anchoring exists to survive.
local REFRESH_DEBOUNCE_MS = 250

-- input() reads a line, so it can never hand one back: free to mean "cancelled".
local CANCELLED = "\r"

-- One write per burst of answers rather than one per file.
local SAVE_DEBOUNCE_MS = 1000

-- Not <C-n>/<C-p>: plugin/multicursor.lua owns those, and shadowing them would mean
-- deleting a user mapping on close. `h` is free across mini.bracketed's targets.
-- Next first — the bindings and `?` both index this order.
local STEP_KEYS = { "]h", "[h" }

local M = {}

local ns = vim.api.nvim_create_namespace("changeset")
local augroup = vim.api.nvim_create_augroup("changeset", { clear = true })

---@class changeset.Session
---@field root string
---@field base string
---@field ref string Ref the fork point was measured against, e.g. "origin/trunk".
---@field branch string
---@field file string Preferences file for this changeset session.
---@field default_branch string
---@field files changeset.File[]
---@field symbols table<string, changeset.CachedSymbol[]> Absent key means "still resolving".
---@field rows changeset.Row[]
---@field visible changeset.Row[]
---@field st changeset.State
---@field query string
---@field hidden table<string, true> Symbol kinds the tree is not showing.
---@field cancel fun()?
---@field timer uv.uv_timer_t?
---@field request table? The refresh whose answers this session is still listening for.

---@type changeset.Session?
local session

---Symbols read for the repo at `root`, carried between openings and to disk.
---@type { root: string, entries: table<string, changeset.CacheEntry> }?
local memo

---@type uv.uv_timer_t?
local save_timer

---Folds outlive a close, so reopening the sidebar looks like you left it. Kept per
---repository: row ids start at a repo-relative path, so one table would share a fold
---between two checkouts that both have a `lua/config/options.lua`.
---@type table<string, changeset.State>
local folds = {}

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
---@param path string Repo-relative.
---@return boolean
local function unwritten(path)
  local buf = vim.fn.bufnr(session.root .. "/" .. path)
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
  if row and row.lnum and row.kind ~= "file" then
    window.preview(session.root .. "/" .. row.path, row.lnum, band_for(row))
  elseif row and row.kind == "file" and row.status == "deleted" then
    window.preview_notice("This file was deleted on this branch", band_for(row))
  elseif row and row.kind == "file" then
    window.preview(session.root .. "/" .. row.path, 1, band_for(row))
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

---Total the branch's line changes into the sidebar's winbar.
---@param win integer
---@param files changeset.File[]
---@param base_ref string
local function set_header(win, files, base_ref)
  local added, removed = 0, 0
  for _, file in ipairs(files) do
    added, removed = added + (file.added or 0), removed + (file.removed or 0)
  end
  vim.wo[win].winbar = render.header({
    base_ref = base_ref,
    files = #files,
    added = added,
    removed = removed,
  })
end

local function draw()
  local buf, win = window.buf(), window.win()
  if not (buf and win and vim.api.nvim_buf_is_valid(buf)) then
    return
  end

  local wanted = (row_at_cursor() or {}).id
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
  if #text == 0 then
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

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  apply_marks(buf, lines)
  hidden_note_line(buf, #text - 1, width, view.hiding(view.kind_counts(session.rows), session.hidden))

  local ids = vim.tbl_map(function(row)
    return row.id
  end, session.visible)
  vim.api.nvim_win_set_cursor(win, { state._reanchor(ids, wanted, previous_line), 0 })

  set_header(win, session.files, session.ref)
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
  local full = session.root .. "/" .. path
  local buf = vim.fn.bufnr(full)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    return vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1]
  end
  local ok, lines = pcall(vim.fn.readfile, full, "", lnum)
  return ok and lines[lnum] or nil
end

local function rebuild()
  session.rows = tree.build(session.files, session.symbols, line_text)
  draw()
end

---@param row changeset.Row
---@param open boolean
local function set_open(row, open)
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
  if not row then
    return
  end
  if row.kind == "file" and row.status == "deleted" then
    return vim.notify(row.path .. " was deleted on this branch — :CodeDiff to read it", vim.log.levels.INFO)
  end
  window.commit(session.root .. "/" .. row.path, row.lnum or 1, how)
end

---@param delta integer
local function step(delta)
  local win = window.win()
  if not (session and win) then
    return
  end
  local lnum = math.max(1, math.min(vim.api.nvim_win_get_cursor(win)[1] + delta, #session.visible))
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
    sidebar = window.win(),
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
    end, open_session.rows)
  )
  draw()
end

---@param buf integer
local function set_keymaps(buf)
  local set, own = help.mapper(buf)
  -- The window can outlive the session: a `:q` mid-rebuild, or the tabpage's last
  -- window, which cannot be closed. Handing the session down rather than letting
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
  map("L", function(open_session)
    state.expand_all(open_session.st)
    draw()
  end, "Expand every file")
  map("R", M.refresh, "Rebuild the tree")
  map("y", function()
    local row = row_at_cursor()
    if row then
      Paths.copy(row.lnum and ("%s:%d"):format(row.path, row.lnum) or row.path, "relative path:line")
    end
  end, "Yank path:line")
  map("?", function()
    help.show(buf, own, STEP_KEYS)
  end, "Show these keymaps")
  map("F", open_kind_menu, "Filter by symbol kind")
  map("f", prompt_filter, "Filter the tree")
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
  -- has to be dropped, and a session opened later starts from a table of its own.
  local request = {}
  session.request = request

  local diff = require("plugins.changeset.diff")
  diff.collect(session.base, session.root, function(files, err)
    if not session or session.request ~= request then
      return
    end
    if not files then
      return vim.notify("Changeset: " .. (err or "git failed"), vim.log.levels.ERROR)
    end
    session.files = files

    -- Stamped before the request rather than after: a file edited while its
    -- symbols are being read then fails this check next time, instead of
    -- leaving behind an answer for content that has already moved on.
    local stamps = {}
    local known, unknown = cache.fresh(memo.entries, files, function(path)
      stamps[path] = cache.stamp(session.root .. "/" .. path)
      return stamps[path]
    end)
    session.symbols = known

    -- Down to what this diff needs: the file caches the branch being read, not
    -- every file whose symbols have ever been asked for.
    memo.entries = {}
    for path, symbols in pairs(known) do
      memo.entries[path] = { stamp = stamps[path], symbols = symbols }
    end
    rebuild()

    -- A server that answers nothing is "resolved with no symbols", which is what
    -- turns every hunk in an unsupported file into an orphan row. Leaving the key
    -- absent would instead read as "still resolving", forever.
    session.cancel = resolve.start(session.root, unknown, function(path, items)
      if not session or session.request ~= request then
        return
      end
      session.symbols[path] = items or {}
      -- Only an answer that arrived is filed. A server that never attached would
      -- otherwise leave "this file has no symbols" on disk, fresh until the file
      -- next moves; and a stamp taken off the file cannot describe what a server
      -- read out of a buffer holding unwritten edits.
      if items and stamps[path] and not unwritten(path) then
        memo.entries[path] = { stamp = stamps[path], symbols = cache.project(items) }
        save_soon()
      end
      rebuild()
    end)
  end)
end

---Open the sidebar on the current buffer's repository and kick off the first refresh.
function M.open()
  if session then
    M.close()
  end
  -- The buffer's repository, not Neovim's directory: with the two different, a base
  -- measured in the wrong one leaves every later `git diff` on a bad object.
  local root = Paths.root(0)
  local preferences_file = prefs.path()
  local base, _, ref = Git.merge_base(root)
  if not base then
    return vim.notify("Changeset: no merge base with the default branch", vim.log.levels.WARN)
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "changeset"
  vim.bo[buf].buftype = "nofile"
  -- Wiped with its window. A scratch buffer is kept otherwise, so every close would
  -- leave one behind, its extmarks and its fifteen mappings included.
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false

  if not memo or memo.root ~= root then
    memo = { root = root, entries = cache.load(cache.path(root)) }
  end

  folds[root] = folds[root] or state.new()
  local default_branch = Git.default_base(root)
  local branch = Git.lines({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, root)[1] or "HEAD"
  session = {
    root = root,
    base = base,
    ref = ref or default_branch,
    branch = branch,
    file = preferences_file,
    default_branch = default_branch,
    files = {},
    symbols = {},
    rows = {},
    visible = {},
    st = folds[root],
    query = "",
    hidden = prefs.resolve(prefs.load(preferences_file), root, branch),
  }

  render.define_highlights()
  local win = window.open(buf)
  set_keymaps(buf)

  -- Fires: the sidebar's window going without the plugin being asked — `:q`, `:only`,
  -- `:tabclose`, a layout plugin. Scheduled because the window is still in the layout
  -- while this runs, and `close` reads the layout to decide where to leave the cursor.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    pattern = tostring(win),
    desc = "changeset: let go of the session when its window closes another way",
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
  -- Fires: the cursor entering any window while the sidebar is open. Nested so the
  -- buffer swaps inside the commit fire their autocmds as `<CR>`'s do.
  vim.api.nvim_create_autocmd("WinEnter", {
    group = augroup,
    nested = true,
    desc = "changeset: open a previewed file once the cursor enters its window",
    callback = window.claim,
  })
  vim.keymap.set("n", STEP_KEYS[1], function()
    step(1)
  end, { desc = "Next change (Changeset)" })
  vim.keymap.set("n", STEP_KEYS[2], function()
    step(-1)
  end, { desc = "Previous change (Changeset)" })

  M.refresh()
end

---Dismiss the sidebar, dropping the session, its timers and the global `]h`/`[h` keys.
function M.close()
  if session then
    if session.cancel then
      session.cancel()
    end
    stop(session.timer)
  end
  session = nil
  require("plugins.changeset.menu").close()
  for _, lhs in ipairs(STEP_KEYS) do
    pcall(vim.keymap.del, "n", lhs)
  end
  vim.api.nvim_clear_autocmds({ group = augroup })
  window.close()
end

---Fill the window a restored session left standing where the sidebar was.
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

-- gitsigns publishes this on every sign refresh, so it doubles as a "the diff
-- may have moved" hook — a commit, a write, or a checkout made outside Neovim.
vim.api.nvim_create_autocmd("User", {
  pattern = "GitSignsUpdate",
  group = vim.api.nvim_create_augroup("changeset.watch", { clear = true }),
  desc = "changeset: rebuild the tree after the working tree or branch changes",
  callback = function()
    if not session then
      return
    end
    stop(session.timer)
    session.timer = vim.defer_fn(function()
      if session then
        M.refresh()
      end
    end, REFRESH_DEBOUNCE_MS)
  end,
})

return M
