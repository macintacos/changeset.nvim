---Symbols the sidebar has already read, kept between builds and restarts.
---
---Asking a language server about every changed file is what makes a cold build
---slow, and an answer only goes stale when the file does. Each entry is stamped
---with the file it was read from, so the next build asks a server only about
---what has actually changed since.

local jsonfile = require("helpers.jsonfile")

local M = {}

---@class changeset.CachedSymbol Only what `changeset.tree` reads from a symbol.
---@field name string
---@field kind string
---@field depth integer
---@field lnum integer
---@field range_lnum integer
---@field range_end_lnum integer

---@class changeset.CacheEntry
---@field stamp string The file as it stood when its symbols were read.
---@field symbols changeset.CachedSymbol[]

---Where the cache for the repo at `root` lives. Under `cache` rather than
---`state`: every entry can be read again from a server, so losing the file
---costs a wait and nothing else.
---@param root string Absolute path to the repo root.
---@return string
function M.path(root)
  return vim.fs.joinpath(vim.fn.stdpath("cache"), "changeset", (root:gsub("/", "%%")) .. ".json")
end

---A file's identity: any change to it changes this.
---@param path string Absolute path.
---@return string? nil when the file cannot be read.
function M.stamp(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil
  end
  return ("%d:%d.%d"):format(stat.size, stat.mtime.sec, stat.mtime.nsec)
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
    if entry and now and entry.stamp == now then
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
    }
  end, items)
end

---Read the entries from `file`. Missing or corrupt file yields none.
---@param file string
---@return table<string, changeset.CacheEntry>
function M.load(file)
  return jsonfile.read(file)
end

---Overwrite `file` with `entries`. A cache that cannot be written is not worth
---interrupting anyone over.
---@param file string
---@param entries table<string, changeset.CacheEntry>
function M.save(file, entries)
  jsonfile.write(file, entries)
end

return M
