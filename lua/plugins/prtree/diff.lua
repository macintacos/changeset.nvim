local M = {}

---@class prtree.diff.Stat
---@field added integer
---@field removed integer

---@class prtree.diff.Entry
---@field status "added"|"modified"|"deleted"|"renamed"
---@field oldpath string? Previous path, renames only.

---@class prtree.diff.Parts
---@field numstat table<string, prtree.diff.Stat> By new path.
---@field statuses table<string, prtree.diff.Entry> By new path.
---@field hunks table<string, prtree.Hunk[]> By new path.
---@field untracked table<string, integer> Line count by path.

-- Any other name-status code (M, T) reads as a modification.
---@type table<string, "added"|"deleted">
local STATUS = { A = "added", D = "deleted" }

---The new path from a numstat path column, which is `old => new` or, when old and new share
---a prefix or suffix, `prefix/{old => new}/suffix`.
---@param field string
---@return string
local function new_path(field)
  local prefix, new, suffix = field:match("^(.*){.- => (.-)}(.*)$")
  if prefix then
    return ((prefix .. new .. suffix):gsub("//", "/"))
  end
  return field:match("^.- => (.+)$") or field
end

---Added and removed line counts per path from `git diff --numstat -M`.
---@param lines string[]
---@return table<string, prtree.diff.Stat> stats By new path; binary files count as 0/0.
function M._parse_numstat(lines)
  local stats = {}
  for _, line in ipairs(lines) do
    local added, removed, field = line:match("^(%S+)\t(%S+)\t(.+)$")
    if field then
      stats[new_path(field)] = { added = tonumber(added) or 0, removed = tonumber(removed) or 0 }
    end
  end
  return stats
end

---Change status per path from `git diff --name-status -M`.
---@param lines string[]
---@return table<string, prtree.diff.Entry> statuses By new path.
function M._parse_name_status(lines)
  local statuses = {}
  for _, line in ipairs(lines) do
    local code, from, to = line:match("^(%u)%d*\t([^\t]+)\t?([^\t]*)$")
    if code == "R" then
      statuses[to] = { status = "renamed", oldpath = from }
    elseif code then
      statuses[from] = { status = STATUS[code] or "modified" }
    end
  end
  return statuses
end

-- A hunk header omits `,count` when the count is 1.
---@param digits string
---@return integer
local function line_count(digits)
  return digits == "" and 1 or tonumber(digits)
end

---@param line string
---@return prtree.Hunk?
local function parse_hunk_header(line)
  local old_count, new_start, new_count = line:match("^@@ %-%d+,?(%d*) %+(%d+),?(%d*) @@")
  if not new_start then
    return nil
  end
  local removed, added = line_count(old_count), line_count(new_count)
  return { lnum = tonumber(new_start), count = added, added = added, removed = removed }
end

---Hunks per path from `git diff --unified=0 --no-color -M`.
---@param lines string[]
---@return table<string, prtree.Hunk[]> hunks By new path; a file with no text hunks maps to `{}`.
function M._parse_hunks(lines)
  local hunks, current = {}, nil
  for _, line in ipairs(lines) do
    local path = line:match("^diff %-%-git a/.+ b/(.+)$")
    if path then
      current = {}
      hunks[path] = current
    else
      local hunk = parse_hunk_header(line)
      if hunk then
        table.insert(current, hunk)
      end
    end
  end
  return hunks
end

---@param path string
---@param entry prtree.diff.Entry
---@param parts prtree.diff.Parts
---@return prtree.File
local function tracked_file(path, entry, parts)
  local stat = parts.numstat[path] or { added = 0, removed = 0 }
  return {
    path = path,
    oldpath = entry.oldpath,
    status = entry.status,
    added = stat.added,
    removed = stat.removed,
    hunks = parts.hunks[path] or {},
  }
end

---@param path string
---@param lines integer
---@return prtree.File
local function untracked_file(path, lines)
  local whole_file = { lnum = 1, count = lines, added = lines, removed = 0 }
  return {
    path = path,
    status = "untracked",
    added = lines,
    removed = 0,
    hunks = lines > 0 and { whole_file } or {},
  }
end

---Join the parsed git output and untracked line counts into files ordered by path.
---@param parts prtree.diff.Parts
---@return prtree.File[]
function M._assemble(parts)
  local files = {}
  for path, entry in pairs(parts.statuses) do
    table.insert(files, tracked_file(path, entry, parts))
  end
  for path, lines in pairs(parts.untracked) do
    table.insert(files, untracked_file(path, lines))
  end
  table.sort(files, function(a, b)
    return a.path < b.path
  end)
  return files
end

-- quotepath=off keeps non-ASCII paths as real filenames instead of quoted escapes.
---@param base string
---@return table<string, string[]> argv By result name.
local function git_commands(base)
  local git = { "git", "-c", "core.quotepath=off" }
  local function cmd(...)
    return vim.list_extend(vim.list_slice(git), { ... })
  end
  return {
    numstat = cmd("diff", "--numstat", "--no-color", "-M", base),
    name_status = cmd("diff", "--name-status", "--no-color", "-M", base),
    hunks = cmd("diff", "--unified=0", "--no-color", "-M", base),
    untracked = cmd("ls-files", "--others", "--exclude-standard"),
  }
end

---Run every command concurrently and hand all results to `on_done` on the main loop.
---@param commands table<string, string[]>
---@param cwd string
---@param on_done fun(results: table<string, vim.SystemCompleted>)
local function run_all(commands, cwd, on_done)
  local results, pending = {}, vim.tbl_count(commands)
  for name, argv in pairs(commands) do
    vim.system(argv, { cwd = cwd, text = true }, function(result)
      results[name] = result
      pending = pending - 1
      if pending == 0 then
        vim.schedule(function()
          on_done(results)
        end)
      end
    end)
  end
end

---@param results table<string, vim.SystemCompleted>
---@return string? stderr Of a failed command, if any.
local function first_failure(results)
  for _, result in pairs(results) do
    if result.code ~= 0 then
      return vim.trim(result.stderr)
    end
  end
end

---@param result vim.SystemCompleted
---@return string[]
local function stdout_lines(result)
  return vim.split(result.stdout, "\n", { trimempty = true })
end

---Line count per readable file; directories (untracked nested repos) and dangling symlinks are skipped.
---@param paths string[] Relative to `cwd`.
---@param cwd string
---@return table<string, integer>
local function count_lines(paths, cwd)
  local counts = {}
  for _, path in ipairs(paths) do
    local abs = vim.fs.joinpath(cwd, path)
    if vim.fn.filereadable(abs) == 1 then
      counts[path] = #vim.fn.readfile(abs)
    end
  end
  return counts
end

---Files changed between `base` and the working tree, plus untracked files.
---Calls back on the main loop with the files, or `nil` and git's stderr when any git command fails.
---@param base string Commit-ish to diff against.
---@param cwd string Repository root; untracked paths are relative to it, like the diff paths.
---@param callback fun(files: prtree.File[]?, err: string?)
function M.collect(base, cwd, callback)
  run_all(git_commands(base), cwd, function(results)
    local err = first_failure(results)
    if err then
      return callback(nil, err)
    end
    callback(M._assemble({
      numstat = M._parse_numstat(stdout_lines(results.numstat)),
      statuses = M._parse_name_status(stdout_lines(results.name_status)),
      hunks = M._parse_hunks(stdout_lines(results.hunks)),
      untracked = count_lines(stdout_lines(results.untracked), cwd),
    }))
  end)
end

return M
