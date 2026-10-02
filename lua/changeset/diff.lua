---Runs the branch's git diff and parses it into files and hunks, and reads a file's text at the base.

local sections = require("changeset.sections")

local M = {}

---@class changeset.Hunk A run of changed lines, in new-file coordinates.
---@field lnum integer   First new line; a pure deletion sits on the line it followed, which is 0 at the top of a file.
---@field count integer  New lines the hunk covers; 0 for a pure deletion.
---@field added integer
---@field removed integer
---@field old_lnum integer First old line; with no removed lines, the one the addition followed, 0 at the top.

---@class changeset.File A changed file and the hunks inside it.
---@field path string      Repo-relative, the new path for a rename.
---@field oldpath string?  Previous path, renames only.
---@field status "added"|"modified"|"deleted"|"renamed"|"untracked"
---@field added integer
---@field removed integer
---@field hunks changeset.Hunk[] Ascending by line, as git emits them; empty for a binary or pure rename.
---@field section changeset.SectionKey The section `sections.classify` files it under, decided once when the diff is read.

---@class changeset.diff.Stat
---@field added integer
---@field removed integer

---@class changeset.diff.Entry
---@field status "added"|"modified"|"deleted"|"renamed"
---@field oldpath string? Previous path, renames only.

---@class changeset.diff.Parts
---@field numstat table<string, changeset.diff.Stat> By new path.
---@field statuses table<string, changeset.diff.Entry> By new path.
---@field hunks table<string, changeset.Hunk[]> By new path.
---@field untracked table<string, integer> Line count by path.

-- Any other name-status code (M, T) reads as a modification.
---@type table<string, "added"|"deleted">
local STATUS = { A = "added", D = "deleted" }

---@type table<string, string>
local ESCAPE = { ['"'] = '"', ["\\"] = "\\", t = "\t", n = "\n", r = "\r" }

---Undo git's C-quoting. `core.quotepath=off` stops it for non-ASCII bytes only, so a
---path holding `"`, `\` or a control character still arrives quoted and escaped.
---@param inner string Text between the quotes.
---@return string
local function unescape(inner)
  return (inner:gsub("\\(.)", ESCAPE))
end

---@param field string A path column, quoted or bare.
---@return string
local function unquote(field)
  local inner = field:match('^"(.*)"$')
  return inner and unescape(inner) or field
end

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
---@return table<string, changeset.diff.Stat> stats By new path; binary files count as 0/0.
function M._parse_numstat(lines)
  local stats = {}
  for _, line in ipairs(lines) do
    local added, removed, field = line:match("^(%S+)\t(%S+)\t(.+)$")
    if field then
      stats[new_path(unquote(field))] = { added = tonumber(added) or 0, removed = tonumber(removed) or 0 }
    end
  end
  return stats
end

---Change status per path from `git diff --name-status -M`.
---@param lines string[]
---@return table<string, changeset.diff.Entry> statuses By new path.
function M._parse_name_status(lines)
  local statuses = {}
  for _, line in ipairs(lines) do
    local code, from, to = line:match("^(%u)%d*\t([^\t]+)\t?([^\t]*)$")
    if code == "R" then
      statuses[unquote(to)] = { status = "renamed", oldpath = unquote(from) }
    elseif code then
      statuses[unquote(from)] = { status = STATUS[code] or "modified" }
    end
  end
  return statuses
end

-- A hunk header omits `,count` when the count is 1.
---@param digits string
---@return integer
local function line_count(digits)
  return digits == "" and 1 or tonumber(digits) --[[@as integer]]
end

---@param line string
---@return changeset.Hunk?
local function parse_hunk_header(line)
  local old_start, old_count, new_start, new_count = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
  if not new_start then
    return nil
  end
  local removed, added = line_count(old_count), line_count(new_count)
  return { lnum = tonumber(new_start), count = added, added = added, removed = removed, old_lnum = tonumber(old_start) }
end

---Hunks per path from `git diff --unified=0 -M`.
---@param lines string[]
---@return table<string, changeset.Hunk[]> hunks By new path; a file with no text hunks maps to `{}`.
function M._parse_hunks(lines)
  local hunks, current = {}, nil
  for _, line in ipairs(lines) do
    local path = line:match("^diff %-%-git a/.+ b/(.+)$")
    -- The other header shape: git quotes each side whole, so `b/` sits inside the quotes.
    local quoted = not path and line:match('^diff %-%-git "a/.+" "b/(.+)"$')
    if path or quoted then
      current = {}
      local name = path or unescape(quoted --[[@as string]])
      hunks[name] = current
    else
      local hunk = parse_hunk_header(line)
      -- A hunk before any header means a shape this does not read. Dropping it costs one
      -- file's hunks; appending it to the file before would misattribute them.
      if hunk and current then
        table.insert(current, hunk)
      end
    end
  end
  return hunks
end

---@param path string
---@param entry changeset.diff.Entry
---@param parts changeset.diff.Parts
---@return changeset.File
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
---@return changeset.File
local function untracked_file(path, lines)
  local whole_file = { lnum = 1, count = lines, added = lines, removed = 0, old_lnum = 0 }
  return {
    path = path,
    status = "untracked",
    added = lines,
    removed = 0,
    hunks = lines > 0 and { whole_file } or {},
  }
end

---Paths `git check-attr -z` output says are `linguist-generated`: any value but `unset`, `false` or `unspecified`.
---@param stdout string `<path>\0<attribute>\0<info>\0`, repeated.
---@return table<string, true>
function M._parse_check_attr(stdout)
  local marked, fields = {}, vim.split(stdout, "\0", { plain = true })
  for i = 1, #fields - 2, 3 do
    local value = fields[i + 2]
    if value ~= "unset" and value ~= "false" and value ~= "unspecified" then
      marked[fields[i]] = true
    end
  end
  return marked
end

---Whether a Go file's header marks it generated: a `// Code generated … DO NOT EDIT.` line before its package clause.
---@param lines fun(): string? Its lines, from the top.
---@return boolean
function M._generated_header(lines)
  for line in lines do
    if line:find("^package%s") then
      return false
    end
    if line:find("^// Code generated .* DO NOT EDIT%.\r?$") then
      return true
    end
  end
  return false
end

-- ponytail: plain string order, so a sibling like "a-x" can split a/'s subtree; compare segment-wise if that shows up.
---Sort key that keeps a directory's files together, root files first.
---@param path string
---@return string dir
---@return string name
local function sort_key(path)
  local dir = vim.fs.dirname(path)
  return dir == "." and "" or dir, vim.fs.basename(path)
end

---Join the parsed git output and untracked counts into files ordered by directory, then name.
---@param parts changeset.diff.Parts
---@return changeset.File[]
function M._assemble(parts)
  local files = {}
  for path, entry in pairs(parts.statuses) do
    table.insert(files, tracked_file(path, entry, parts))
  end
  for path, lines in pairs(parts.untracked) do
    table.insert(files, untracked_file(path, lines))
  end
  table.sort(files, function(a, b)
    local a_dir, a_name = sort_key(a.path)
    local b_dir, b_name = sort_key(b.path)
    if a_dir ~= b_dir then
      return a_dir < b_dir
    end
    return a_name < b_name
  end)
  return files
end

-- These pin output the user's own git config can otherwise reshape: quotepath keeps
-- non-ASCII paths as real filenames, and the prefix, colour and external-driver flags
-- keep the `diff --git a/x b/x` header the hunk parser reads.
---@param base string
---@return table<string, string[]> argv By result name.
local function git_commands(base)
  local git = { "git", "-c", "core.quotepath=off" }
  local function cmd(...)
    return vim.list_extend(vim.list_slice(git), { ... })
  end
  local function diff_cmd(...)
    return cmd("diff", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", "-M", ...)
  end
  return {
    numstat = diff_cmd("--numstat", base),
    name_status = diff_cmd("--name-status", base),
    hunks = diff_cmd("--unified=0", base),
    untracked = cmd("ls-files", "--others", "--exclude-standard"),
    commits = cmd("rev-list", "--count", base .. "..HEAD"),
  }
end

---`vim.system`, but a failed spawn — a repository removed under a pending refresh —
---reaches `on_exit` as a failed result instead of raising.
---@param argv string[]
---@param opts vim.SystemOpts
---@param on_exit fun(result: vim.SystemCompleted)
local function system(argv, opts, on_exit)
  local ok, err = pcall(vim.system, argv, opts, on_exit)
  if not ok then
    local result = { code = -1, signal = 0, stdout = "", stderr = tostring(err) }
    vim.schedule(function()
      on_exit(result)
    end)
  end
end

---Run every command concurrently and hand all results to `on_done` on the main loop.
---@param commands table<string, string[]>
---@param cwd string
---@param on_done fun(results: table<string, vim.SystemCompleted>)
local function run_all(commands, cwd, on_done)
  local results, pending = {}, vim.tbl_count(commands)
  for name, argv in pairs(commands) do
    system(argv, { cwd = cwd, text = true }, function(result)
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

---Whether the Go file at `abs` has a generated header; false when it can't be read.
---@param abs string
---@return boolean
local function go_file_generated(abs)
  -- io.open succeeds on a directory (a submodule gitlink), where f:lines() raises.
  if vim.fn.filereadable(abs) ~= 1 then
    return false
  end
  local f = io.open(abs)
  if not f then
    return false
  end
  local generated = M._generated_header(f:lines())
  f:close()
  return generated
end

---Paths among `files` that their Go header or `.gitattributes` marks generated; calls back on the main loop.
---@param files changeset.File[]
---@param cwd string
---@param on_done fun(marked: table<string, true>)
local function generated_paths(files, cwd, on_done)
  local paths = vim.tbl_map(function(file)
    return file.path
  end, files)
  system(
    { "git", "check-attr", "-z", "--stdin", "linguist-generated" },
    { cwd = cwd, text = true, stdin = table.concat(paths, "\0") },
    function(result)
      vim.schedule(function()
        -- A failed read only costs files their Generated section.
        local marked = result.code == 0 and M._parse_check_attr(result.stdout) or {}
        for _, file in ipairs(files) do
          if
            file.status ~= "deleted"
            and vim.endswith(file.path, ".go")
            and go_file_generated(vim.fs.joinpath(cwd, file.path))
          then
            marked[file.path] = true
          end
        end
        on_done(marked)
      end)
    end
  )
end

---Files changed between `base` and the working tree, plus untracked files, each marked `generated`
---when its Go header or `.gitattributes` says so; and the commits made since `base`.
---Calls back on the main loop with those, or `nil` and the error when any git command fails or cannot start.
---@param base string Commit-ish to diff against.
---@param cwd string Repository root; untracked paths are relative to it, like the diff paths.
---@param callback fun(files: changeset.File[]?, err: string?, commits: integer?)
function M.collect(base, cwd, callback)
  run_all(git_commands(base), cwd, function(results)
    local err = first_failure(results)
    if err then
      return callback(nil, err)
    end
    local files = M._assemble({
      numstat = M._parse_numstat(stdout_lines(results.numstat)),
      statuses = M._parse_name_status(stdout_lines(results.name_status)),
      hunks = M._parse_hunks(stdout_lines(results.hunks)),
      untracked = count_lines(stdout_lines(results.untracked), cwd),
    })
    generated_paths(files, cwd, function(marked)
      for _, file in ipairs(files) do
        file.section = sections.classify(file.path, marked[file.path])
      end
      callback(files, nil, tonumber(stdout_lines(results.commits)[1]))
    end)
  end)
end

---The text of `object`, such as `<base>:<path>`, calling back on the main loop with nil when git cannot read it.
---@param object string
---@param cwd string
---@param callback fun(text: string?)
function M.blob(object, cwd, callback)
  system({ "git", "cat-file", "blob", object }, { cwd = cwd, text = true }, function(result)
    vim.schedule(function()
      callback(result.code == 0 and result.stdout or nil)
    end)
  end)
end

return M
