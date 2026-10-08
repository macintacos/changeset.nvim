---Symbols the sidebar has already read, kept between builds and restarts.
---
---Asking a language server about every changed file is what makes a cold build
---slow, and an answer only goes stale when the file does. Each entry is stamped
---with the file it was read from, so the next build asks a server only about
---what has actually changed since.

local jsonfile = require("changeset.jsonfile")

local M = {}

---@class changeset.CachedSymbol Only what `changeset.rows` reads from a symbol.
---@field name string
---@field kind string
---@field depth integer
---@field lnum integer
---@field range_lnum integer
---@field range_end_lnum integer
---@field test true? The syntax marked it an inline test; kept so a cached file is never parsed again.

---@class changeset.CacheEntry
---@field stamp string The file as it stood when its symbols were read.
---@field symbols changeset.CachedSymbol[]
---@field comments changeset.Comments? Which of the file's lines are comments, at its base and now; nil when none were read or parsed.
---@field silent true? No server answered for the file. Kept out of the file on disk: a
---server installed or started later must get asked, where one Neovim can stop asking.

-- Bump when what an entry holds or how it is derived changes: an older entry's stamp still matches, so it
-- would be read back as it was.
local FORMAT = 5

---Where the cache for the repo at `root` lives. Under `cache` rather than
---`state`: every entry can be read again from a server, so losing the file
---costs a wait and nothing else.
---@param root string Absolute path to the repo root.
---@return string
function M.path(root)
  return vim.fs.joinpath(vim.fn.stdpath("cache"), "changeset", ("%s.v%d.json"):format((root:gsub("/", "%%")), FORMAT))
end

---A file's identity against `base`: any change to the file, or a moved base, changes this.
---@param path string Absolute path.
---@param base string The commit its base side is read from.
---@return string? nil when the file cannot be read.
function M.stamp(path, base)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil
  end
  return ("%s:%d:%d.%d"):format(base, stat.size, stat.mtime.sec, stat.mtime.nsec)
end

---Split `files` into the symbols already known for them and the ones a server
---still has to answer for.
---@param entries table<string, changeset.CacheEntry>
---@param files changeset.File[]
---@param stamp fun(path: string): string? The file's stamp now.
---@return table<string, changeset.CachedSymbol[]> known Keyed by path.
---@return changeset.File[] unknown
function M.fresh(entries, files, stamp)
  local known, unknown = {}, {}
  for _, file in ipairs(files) do
    local entry = entries[file.path]
    local now = stamp(file.path)
    if type(entry) == "table" and type(entry.symbols) == "table" and now and entry.stamp == now then
      known[file.path] = entry.symbols
    else
      unknown[#unknown + 1] = file
    end
  end
  return known, unknown
end

---Only the fields the tree reads, so the file stays small and its contents stay
---legible.
---@param items table[] As `changeset.resolve` hands them over.
---@return changeset.CachedSymbol[]
function M.project(items)
  return vim.tbl_map(function(item)
    return {
      name = item.name,
      kind = item.kind,
      depth = item.depth,
      lnum = item.lnum,
      range_lnum = item.range_lnum,
      range_end_lnum = item.range_end_lnum,
      test = item.test,
    }
  end, items)
end

---Read the entries from `file`. Missing or corrupt file yields none.
---@param file string
---@return table<string, changeset.CacheEntry>
function M.load(file)
  return jsonfile.read(file)
end

---Overwrite `file` with `entries`, leaving out the `silent` ones. A cache that cannot
---be written is not worth interrupting anyone over.
---@param file string
---@param entries table<string, changeset.CacheEntry>
function M.save(file, entries)
  local answered = {}
  for path, entry in pairs(entries) do
    if not entry.silent then
      answered[path] = entry
    end
  end
  jsonfile.write(file, answered)
end

return M
