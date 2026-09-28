---Row icons: mini.icons when it is set up, else nvim-web-devicons for files, else a blank glyph.

local M = {}

---@alias changeset.IconProvider fun(category: string, name: string): string?, string?

---@type changeset.IconProvider?
local provider

---@return changeset.IconProvider
local function detect()
  if _G.MiniIcons then
    return _G.MiniIcons.get
  end
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if not ok then
    return function() end
  end
  -- devicons knows files only; directories and LSP kinds fall through to the blank.
  return function(category, name)
    if category == "file" then
      return devicons.get_icon(vim.fs.basename(name), nil, { default = true })
    end
  end
end

---Glyph and highlight group for `name` in a mini.icons `category`. The provider is
---picked on the first call and kept for the session.
---@param category "directory"|"file"|"lsp"
---@param name string
---@return string glyph, string hl
function M.get(category, name)
  provider = provider or detect()
  local glyph, hl = provider(category, name)
  if glyph then
    return glyph, hl
  end
  return " ", "Normal"
end

return M
