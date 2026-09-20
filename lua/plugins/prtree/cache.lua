---Symbols the sidebar has already read, kept between openings and restarts.
---
---Asking a language server about every changed file is what makes the first
---open slow, and an answer only goes stale when the file does. Each entry is
---stamped with the file it was read from, so reopening asks a server only about
---what has actually changed since.

local M = {}

---@class prtree.CachedSymbol Only what `prtree.tree` reads from a symbol.
---@field name string
---@field kind string
---@field depth integer
---@field lnum integer
---@field range_lnum integer
---@field range_end_lnum integer

---@class prtree.CacheEntry
---@field stamp string The file as it stood when its symbols were read.
---@field symbols prtree.CachedSymbol[]

---Where the cache for the repo at `root` lives. Under `cache` rather than
---`state`: every entry can be read again from a server, so losing the file
---costs a wait and nothing else.
---@param root string Absolute path to the repo root.
---@return string
function M.path(root)
  return vim.fs.joinpath(vim.fn.stdpath("cache"), "prtree", (root:gsub("/", "%%")) .. ".json")
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
---@param entries table<string, prtree.CacheEntry>
---@param files prtree.File[]
---@param stamp fun(path: string): string? The file's stamp now.
---@return table<string, prtree.CachedSymbol[]> known Keyed by path.
---@return prtree.File[] unknown
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
---@param items table[] As `prtree.resolve` hands them over.
---@return prtree.CachedSymbol[]
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
---@return table<string, prtree.CacheEntry>
function M.load(file)
  local fd = io.open(file, "r")
  if not fd then
    return {}
  end
  local content = fd:read("*a")
  fd:close()
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then
    return {}
  end
  return data
end

---Overwrite `file` with `entries`. A cache that cannot be written is not worth
---interrupting anyone over.
---@param file string
---@param entries table<string, prtree.CacheEntry>
function M.save(file, entries)
  vim.fn.mkdir(vim.fs.dirname(file), "p")
  local fd = io.open(file, "w")
  if not fd then
    return
  end
  fd:write(vim.json.encode(entries))
  fd:close()
end

return M
