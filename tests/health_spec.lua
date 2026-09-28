describe("changeset.health", function()
  local health = require("changeset.health")
  local config = require("changeset.config")
  local icons = require("changeset.icons")
  local MODULES = { "which-key", "mini.pick", "gitsigns" }

  local saved, missing, source, clients, no_parser

  local function installed(name)
    package.loaded[name] = nil
    package.preload[name] = function()
      return {}
    end
  end

  local function absent(name)
    package.loaded[name] = nil
    package.preload[name] = function()
      error("not installed")
    end
  end

  ---@return string?
  local function level(text)
    for _, section in ipairs(health._report()) do
      for _, finding in ipairs(section.findings) do
        if finding.msg:find(text, 1, true) then
          return finding.level
        end
      end
    end
  end

  before_each(function()
    saved = {
      has = vim.fn.has,
      executable = vim.fn.executable,
      get_clients = vim.lsp.get_clients,
      add = vim.treesitter.language.add,
      source = icons.source,
      MiniPick = MiniPick,
      loaded = {},
      preload = {},
    }
    for _, name in ipairs(MODULES) do
      saved.loaded[name] = package.loaded[name]
      saved.preload[name] = package.preload[name]
      absent(name)
    end
    missing, source, clients, no_parser = {}, "mini.icons", {}, {}
    vim.fn.has = function(feature)
      if feature == "nvim-0.12" then
        return missing[feature] and 0 or 1
      end
      return saved.has(feature)
    end
    vim.fn.executable = function(name)
      if name == "git" or name == "gh" then
        return missing[name] and 0 or 1
      end
      return saved.executable(name)
    end
    vim.lsp.get_clients = function()
      return clients
    end
    vim.treesitter.language.add = function(lang)
      if no_parser[lang] then
        error("no parser")
      end
      return true
    end
    icons.source = function()
      return source
    end
    MiniPick = nil
  end)

  after_each(function()
    vim.fn.has = saved.has
    vim.fn.executable = saved.executable
    vim.lsp.get_clients = saved.get_clients
    vim.treesitter.language.add = saved.add
    icons.source = saved.source
    MiniPick = saved.MiniPick
    for _, name in ipairs(MODULES) do
      package.loaded[name] = saved.loaded[name]
      package.preload[name] = saved.preload[name]
    end
    config.setup()
  end)

  it("reports the running Neovim when it is 0.12 or newer", function()
    assert.equal("ok", level("Neovim "))
  end)

  it("errors when Neovim is older than 0.12", function()
    missing["nvim-0.12"] = true
    assert.equal("error", level("Neovim 0.12 or newer is required"))
  end)

  it("reports git, and errors without it", function()
    assert.equal("ok", level("`git` found"))
    missing.git = true
    assert.equal("error", level("`git` not found"))
  end)

  it("reports gh, and warns without it", function()
    assert.equal("ok", level("`gh` found"))
    missing.gh = true
    assert.equal("warn", level("`gh` not found"))
  end)

  it("reports the icon provider, and warns without one", function()
    assert.equal("ok", level("icons from `mini.icons`"))
    source = "nvim-web-devicons"
    assert.equal("ok", level("icons from `nvim-web-devicons`"))
    source = nil
    assert.equal("warn", level("no icon provider"))
  end)

  it("reports which-key as ok when installed, info when not", function()
    assert.equal("info", level("`which-key` not found"))
    installed("which-key")
    assert.equal("ok", level("`which-key` found"))
  end)

  it("reports mini.pick as ok only when installed and set up", function()
    assert.equal("info", level("`mini.pick` not found"))
    installed("mini.pick")
    assert.equal("info", level("`mini.pick` is installed but not set up"))
    MiniPick = {}
    assert.equal("ok", level("`mini.pick` found"))
  end)

  it("errors on a missing gitsigns only while PR Review Mode is enabled", function()
    assert.equal("info", level("`gitsigns` not found"))
    config.setup({ pr_review = { enabled = true } })
    assert.equal("error", level("`gitsigns` not found"))
    installed("gitsigns")
    assert.equal("ok", level("`gitsigns` found"))
  end)

  it("names the language servers that provide symbols", function()
    assert.equal("info", level("textDocument/documentSymbol"))
    clients = { { name = "lua_ls" } }
    assert.equal("info", level("lua_ls"))
  end)

  it("reports each test-symbol parser, and notes a missing one", function()
    no_parser.rust = true
    assert.equal("info", level("no treesitter parser for `rust`"))
    assert.equal("ok", level("treesitter parser for `tsx`"))
  end)

  it("shows the options in force", function()
    assert.equal("info", level("min_file_width"))
  end)

  it("spawns no process and starts no server", function()
    local calls = {}
    local names = { "system", "fn.system", "fn.jobstart", "lsp.start", "lsp.enable" }
    local targets =
      { { vim, "system" }, { vim.fn, "system" }, { vim.fn, "jobstart" }, { vim.lsp, "start" }, { vim.lsp, "enable" } }
    local originals = {}
    for i, t in ipairs(targets) do
      originals[i] = t[1][t[2]]
      t[1][t[2]] = function()
        table.insert(calls, names[i])
      end
    end
    local ok, err = pcall(health._report)
    for i, t in ipairs(targets) do
      t[1][t[2]] = originals[i]
    end
    assert.is_true(ok, tostring(err))
    assert.same({}, calls)
  end)

  it("does not load the plugin's entry module", function()
    health._report()
    assert.is_nil(package.loaded["changeset"])
  end)

  it("check() emits each section and finding through vim.health", function()
    local calls = {}
    local originals = {}
    for _, fn in ipairs({ "start", "ok", "warn", "error", "info" }) do
      originals[fn] = vim.health[fn]
      vim.health[fn] = function(msg)
        table.insert(calls, { fn, msg })
      end
    end
    local ok, err = pcall(health.check)
    for fn, original in pairs(originals) do
      vim.health[fn] = original
    end
    assert.is_true(ok, err)
    local expected = {}
    for _, section in ipairs(health._report()) do
      table.insert(expected, { "start", section.name })
      for _, finding in ipairs(section.findings) do
        table.insert(expected, { finding.level, finding.msg })
      end
    end
    assert.same(expected, calls)
  end)
end)
