---Icons: mini.icons when it is set up, else nvim-web-devicons for files, else a blank glyph.

local M = {}

---@alias changeset.IconProvider fun(category: string, name: string): string?, string?

---@type changeset.IconProvider?
local provider

---The provider `get` would pick now; probes afresh, unlike `get`, which keeps its first pick.
---@return "mini.icons"|"nvim-web-devicons"|nil
function M.source()
  -- First: a devicons shim (LazyVim's) sets mini.icons up as it loads.
  local devicons_loads = pcall(require, "nvim-web-devicons")
  if MiniIcons then
    return "mini.icons"
  end
  return devicons_loads and "nvim-web-devicons" or nil
end

---@return changeset.IconProvider
local function detect()
  local source, mini = M.source(), MiniIcons
  if source == "mini.icons" and mini then
    return mini.get
  end
  if not source then
    return function() end
  end
  local devicons = require("nvim-web-devicons")
  -- devicons knows files only; directories and LSP kinds fall through to the blank.
  return function(category, name)
    if category == "file" then
      return devicons.get_icon(vim.fs.basename(name), nil, { default = true })
    end
  end
end

---Glyph and highlight group for `name` in a mini.icons `category`. The provider is
---kept for the session: `require` does not cache a failure, so a per-icon probe would
---search 'runtimepath' for a missing devicons on every row.
---@param category "directory"|"file"|"lsp"
---@param name string
---@return string glyph, string hl
function M.get(category, name)
  provider = provider or detect()
  local glyph, hl = provider(category, name)
  if glyph then
    return glyph, hl or "Normal"
  end
  return " ", "Normal"
end

return M
