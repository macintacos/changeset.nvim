---The preview beside the base pickers: the sidebar's header for a ref, then the commits and files HEAD has against it,
---measured as the sidebar would measure them once that ref is chosen.
local Git = require("changeset.git")
local cells = require("changeset.cells")
local diff = require("changeset.diff")
local highlights = require("changeset.highlights")
local icons = require("changeset.icons")
local render = require("changeset.render")
local symbols = require("changeset.symbols")

local M = {}

local ns = vim.api.nvim_create_namespace("changeset.base_preview")

-- Enough to say which commits count; more would push the files, which are what the sidebar shows, out of view.
local COMMITS_SHOWN = 5

---@param chunks { [1]: string, [2]: string|string[]|nil }[]
---@param stat? table[]
---@return changeset.Line
local function line(chunks, stat)
  return render.compose(nil, chunks, stat)
end

---@param text string
---@return changeset.Line
local function meta(text)
  return line({ { text, highlights.META_HL } })
end

---A commit HEAD has over the base, as `git log --format='%h %s'` prints it.
---@param entry string
---@param width integer
---@return changeset.Line
local function commit_line(entry, width)
  local sha, subject = entry:match("^(%S+) ?(.*)$")
  assert(subject, "changeset: a commit line without a hash")
  local lead = ("%s %s "):format(render.REF_ICONS.commit, sha)
  return line({ { lead, "Comment" }, { cells.clip(subject, width - cells.width(lead) - 1) } })
end

---@param file changeset.File
---@param width integer
---@return changeset.Line
local function file_line(file, width)
  local glyph, hl = icons.get("file", file.path)
  local stat = render.stat_chunks(file)
  -- The stat ends over the two-cell gutter the sidebar's rows keep, and one more cell keeps it off the path.
  local room = width - cells.width(glyph .. " ") - cells.chunks(stat or {}) - 3
  local dir, name = symbols.fit(file.path, room, "/"):match("^(.-)([^/]*)$")
  assert(dir and name, "changeset: a path the pattern can't split")
  return line({ { glyph .. " ", hl }, { dir, "Comment" }, { name } }, stat)
end

---The lines for a diff that landed: the header's two rows, then the commits, then the files.
---@param head changeset.Line The header's first row.
---@param files changeset.File[]
---@param commits string[]
---@param width integer
---@return changeset.Line[]
local function landed(head, files, commits, width)
  local added, removed = 0, 0
  for _, file in ipairs(files) do
    added, removed = added + (file.added or 0), removed + (file.removed or 0)
  end
  local totals = render.header_totals({
    ref = "",
    files = #files,
    commits = #commits,
    added = added,
    removed = removed,
  }, width)
  local lines = { head, line(totals) }
  ---@param group changeset.Line[]
  local function after_blank(group)
    if #group > 0 then
      lines[#lines + 1] = line({})
      vim.list_extend(lines, group)
    end
  end
  local commit_lines = vim.tbl_map(function(entry)
    return commit_line(entry, width)
  end, vim.list_slice(commits, 1, COMMITS_SHOWN))
  if #commits > COMMITS_SHOWN then
    commit_lines[#commit_lines + 1] = meta(("⋯ %d more"):format(#commits - COMMITS_SHOWN))
  end
  after_blank(commit_lines)
  after_blank(vim.tbl_map(function(file)
    return file_line(file, width)
  end, files))
  return lines
end

---Replace what `buf` shows with `lines`, unless the picker has wiped it since. Redraws: a picker waiting on a key
---repaints nothing by itself.
---@param buf integer
---@param lines changeset.Line[]
local function paint(buf, lines)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_set_lines(
    buf,
    0,
    -1,
    false,
    vim.tbl_map(function(l)
      return l.text
    end, lines)
  )
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, l in ipairs(lines) do
    for _, mark in ipairs(l.marks) do
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, mark.col, {
        end_col = mark.end_col,
        hl_group = mark.hl,
        virt_text = mark.virt_text,
        virt_text_pos = mark.pos,
        hl_mode = mark.hl_mode,
      })
    end
  end
  vim.cmd.redraw()
end

---Show in `buf` what the sidebar of the repository at `root` would hold against `ref`: its header at once, and the
---commits and files once the diff is read, without blocking.
---@param buf integer
---@param root string
---@param ref string
---@param kind changeset.RefKind
function M.show(buf, root, ref, kind)
  local win = vim.fn.bufwinid(buf)
  local width = win ~= -1 and vim.api.nvim_win_get_width(win) or 80
  if win ~= -1 then
    vim.wo[win].wrap = false
  end
  local head = line(render.header_ref(ref, kind, width))
  paint(buf, { head, line({}), meta("⋯ reading the diff") })
  Git.async(function()
    local base = Git.merge_base(root, ref)
    return base and { base = base, commits = Git.lines({ "git", "log", "--format=%h %s", base .. "..HEAD" }, root) }
  end, function(measured)
    if not measured then
      return paint(buf, { head, line({}), meta(("HEAD shares no history with %s"):format(ref)) })
    end
    diff.collect(measured.base, root, function(files, err)
      if not files then
        return paint(buf, { head, line({}), meta(err or "git diff failed") })
      end
      paint(buf, landed(head, files, measured.commits, width))
    end)
  end)
end

return M
