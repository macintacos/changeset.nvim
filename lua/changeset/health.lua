---`:checkhealth changeset`: the requirements and every optional integration. Probes only; changes nothing.
local M = {}

local attributes = require("changeset.attributes")
local config = require("changeset.config")
local icons = require("changeset.icons")

---@alias changeset.health.Level "ok"|"warn"|"error"|"info"

---@class changeset.health.Finding
---@field level changeset.health.Level
---@field msg string

---@class changeset.health.Section
---@field name string
---@field findings changeset.health.Finding[]

---@param level changeset.health.Level
---@param msg string
---@return changeset.health.Finding
local function finding(level, msg)
  return { level = level, msg = msg }
end

---@param name string
---@return boolean
local function loads(name)
  return (pcall(require, name))
end

local function neovim()
  local version = tostring(vim.version())
  if vim.fn.has("nvim-0.12") == 1 then
    return finding("ok", "Neovim " .. version)
  end
  return finding("error", "Neovim 0.12 or newer is required; running " .. version)
end

local function git()
  if vim.fn.executable("git") == 1 then
    return finding("ok", "`git` found")
  end
  return finding("error", "`git` not found: changeset reads every change through it")
end

local function gh()
  if vim.fn.executable("gh") == 1 then
    return finding("ok", "`gh` found")
  end
  return finding("warn", "`gh` not found: PR target branch detection is off")
end

local function icon_provider()
  local source = icons.source()
  if source == "mini.icons" then
    return finding("ok", "icons from `mini.icons`")
  end
  if source then
    return finding("ok", "icons from `nvim-web-devicons` (files only)")
  end
  return finding("warn", "no icon provider: install `mini.icons` or `nvim-web-devicons`")
end

local function which_key()
  if loads("which-key") then
    return finding("ok", "`which-key` found: `?` opens its popup")
  end
  return finding("info", "`which-key` not found: `?` lists the keys in a float")
end

local function mini_pick()
  if not loads("mini.pick") then
    return finding("info", "`mini.pick` not found: the picker is unavailable")
  end
  if not MiniPick then
    return finding("info", "`mini.pick` is installed but not set up: the picker is unavailable")
  end
  return finding("ok", "`mini.pick` found and set up")
end

local function gitsigns()
  if loads("gitsigns") then
    return finding("ok", "`gitsigns` found")
  end
  if config.get().pr_review.enabled then
    return finding("error", "`gitsigns` not found while `pr_review.enabled` is set: PR Review Mode cannot run")
  end
  return finding("info", "`gitsigns` not found: PR Review Mode is unavailable")
end

local function symbols()
  local names = vim.tbl_map(function(client)
    return client.name
  end, vim.lsp.get_clients({ method = "textDocument/documentSymbol" }))
  if #names == 0 then
    return finding(
      "info",
      "no attached language server provides `textDocument/documentSymbol`: files show no symbols until one does"
    )
  end
  return finding("info", "`textDocument/documentSymbol` from " .. table.concat(names, ", "))
end

---@return changeset.health.Finding[]
local function parsers()
  return vim.tbl_map(function(lang)
    if pcall(vim.treesitter.language.add, lang) then
      return finding("ok", ("treesitter parser for `%s` found"):format(lang))
    end
    return finding("info", ("no treesitter parser for `%s`: its test symbols are detected by name only"):format(lang))
  end, attributes.languages())
end

---@return changeset.health.Section[]
function M._report()
  return {
    { name = "Requirements", findings = { neovim(), git() } },
    {
      name = "Optional integrations",
      findings = vim.list_extend({ gh(), icon_provider(), which_key(), mini_pick(), gitsigns(), symbols() }, parsers()),
    },
    { name = "Configuration", findings = { finding("info", vim.inspect(config.get())) } },
  }
end

function M.check()
  for _, section in ipairs(M._report()) do
    vim.health.start(section.name)
    for _, f in ipairs(section.findings) do
      vim.health[f.level](f.msg)
    end
  end
end

return M
