---`:checkhealth changeset`: the requirements and every optional integration. Probes the way the sidebar loads, so a
---lazy-loaded plugin may load and set itself up; `probe` is the only part that touches the world.
local attributes = require("changeset.attributes")
local config = require("changeset.config")
local icons = require("changeset.icons")

local M = {}

---@alias changeset.health.Level "ok"|"warn"|"error"|"info"

---@class changeset.health.Finding
---@field level changeset.health.Level
---@field msg string

---@class changeset.health.Section
---@field name string
---@field findings changeset.health.Finding[]

---What the checks read.
---@class changeset.health.Facts
---@field version string
---@field nvim_012 boolean
---@field git boolean
---@field gh boolean
---@field herdr boolean Inside a herdr pane, with `herdr` executable.
---@field icons "mini.icons"|"nvim-web-devicons"|false|nil
---@field which_key boolean
---@field mini_pick false|"installed"|"set up"
---@field gitsigns boolean
---@field symbol_servers string[]
---@field parsers { lang: string, found: boolean }[]
---@field options changeset.Options

---@param level changeset.health.Level
---@param msg string
---@return changeset.health.Finding
local function finding(level, msg)
  return { level = level, msg = msg }
end

---Whether `name` loads. Requires it as the sidebar does, so a lazy-loading manager loads it first.
---@param name string
---@return boolean
local function loads(name)
  return (pcall(require, name))
end

---@return changeset.health.Facts
local function probe()
  local mini_pick = loads("mini.pick") and (MiniPick and "set up" or "installed")
  return {
    version = (tostring(vim.version()):gsub("%+.*", "")),
    nvim_012 = vim.fn.has("nvim-0.12") == 1,
    git = vim.fn.executable("git") == 1,
    gh = vim.fn.executable("gh") == 1,
    herdr = (vim.env.HERDR_WORKSPACE_ID or "") ~= "" and vim.fn.executable("herdr") == 1,
    icons = icons.source(),
    which_key = loads("which-key"),
    mini_pick = mini_pick,
    gitsigns = loads("gitsigns"),
    symbol_servers = vim.list.unique(vim.tbl_map(function(client)
      return client.name
    end, vim.lsp.get_clients({ method = "textDocument/documentSymbol" }))),
    parsers = vim.tbl_map(function(lang)
      return { lang = lang, found = vim.treesitter.language.add(lang) ~= nil }
    end, attributes.languages()),
    options = config.get(),
  }
end

---@param facts changeset.health.Facts
local function neovim(facts)
  if facts.nvim_012 then
    return finding("ok", "Neovim " .. facts.version)
  end
  return finding("error", "Neovim 0.12 or newer is required; running " .. facts.version)
end

---@param facts changeset.health.Facts
local function git(facts)
  if facts.git then
    return finding("ok", "`git` found")
  end
  return finding("error", "`git` not found: changeset reads every change through it")
end

---@param facts changeset.health.Facts
local function gh(facts)
  if facts.gh then
    return finding("ok", "`gh` found")
  end
  return finding("warn", "`gh` not found: PR target branch detection is off")
end

---@param facts changeset.health.Facts
local function herdr(facts)
  if facts.herdr then
    return finding(
      "ok",
      "running inside herdr: `:Changeset review submit` can paste the review into its agents' prompts"
    )
  end
  return finding(
    "warn",
    "not inside a herdr pane: `:Changeset review submit` has no agent prompt to paste the review into"
  )
end

---@param facts changeset.health.Facts
local function icon_provider(facts)
  if facts.icons == "mini.icons" then
    return finding("ok", "icons from `mini.icons`")
  end
  if facts.icons == "nvim-web-devicons" then
    return finding("ok", "icons from `nvim-web-devicons` (files only)")
  end
  return finding("warn", "no icon provider: install `mini.icons` or `nvim-web-devicons`")
end

---@param facts changeset.health.Facts
local function which_key(facts)
  if facts.which_key then
    return finding("ok", "`which-key` found: `?` opens its popup")
  end
  return finding("info", "`which-key` not found: `?` lists the keys in a float")
end

---@param facts changeset.health.Facts
local function mini_pick(facts)
  if not facts.mini_pick then
    return finding("info", "`mini.pick` not found: the picker is unavailable")
  end
  if facts.mini_pick == "installed" then
    return finding("info", "`mini.pick` is installed but not set up: the picker is unavailable")
  end
  return finding("ok", "`mini.pick` found and set up")
end

---@param facts changeset.health.Facts
local function gitsigns(facts)
  if facts.gitsigns then
    return finding("ok", "`gitsigns` found")
  end
  if facts.options.pr_review.enabled then
    return finding("error", "`gitsigns` not found while `pr_review.enabled` is set: PR Review Mode cannot run")
  end
  return finding("info", "`gitsigns` not found: PR Review Mode is unavailable")
end

---@param facts changeset.health.Facts
local function symbols(facts)
  if #facts.symbol_servers == 0 then
    return finding(
      "info",
      "no attached language server provides `textDocument/documentSymbol`: files show no symbols until one does"
    )
  end
  return finding("info", "`textDocument/documentSymbol` from " .. table.concat(facts.symbol_servers, ", "))
end

---@param facts changeset.health.Facts
---@return changeset.health.Finding[]
local function parsers(facts)
  return vim.tbl_map(function(parser)
    if parser.found then
      return finding("ok", ("treesitter parser for `%s` found"):format(parser.lang))
    end
    return finding(
      "info",
      ("no treesitter parser for `%s`: its test symbols are detected by name only"):format(parser.lang)
    )
  end, facts.parsers)
end

---The findings `check` emits for `facts`, by section. Pure; exposed for the spec.
---@param facts changeset.health.Facts
---@return changeset.health.Section[]
function M._report(facts)
  return {
    { name = "Requirements", findings = { neovim(facts), git(facts) } },
    {
      name = "Optional integrations",
      findings = vim.list_extend({
        gh(facts),
        herdr(facts),
        icon_provider(facts),
        which_key(facts),
        mini_pick(facts),
        gitsigns(facts),
        symbols(facts),
      }, parsers(facts)),
    },
    { name = "Configuration", findings = { finding("info", vim.inspect(facts.options)) } },
  }
end

---The `vim.health` hook: probes, then emits `_report`.
function M.check()
  for _, section in ipairs(M._report(probe())) do
    vim.health.start(section.name)
    for _, f in ipairs(section.findings) do
      vim.health[f.level](f.msg)
    end
  end
end

return M
