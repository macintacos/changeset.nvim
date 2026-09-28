describe("changeset.health", function()
  local health = require("changeset.health")
  local config = require("changeset.config")
  local attributes = require("changeset.attributes")

  local HEALTHY = {
    version = "0.12.5",
    nvim_012 = true,
    git = true,
    gh = true,
    icons = "mini.icons",
    which_key = true,
    mini_pick = "set up",
    gitsigns = true,
    symbol_servers = { "lua_ls" },
    parsers = { { lang = "rust", found = true } },
    options = config.get(),
  }

  ---Level of the first finding, in report order, whose message contains `text`.
  ---@return string?
  local function level(overrides, text)
    for _, section in ipairs(health._report(vim.tbl_extend("force", HEALTHY, overrides))) do
      for _, finding in ipairs(section.findings) do
        if finding.msg:find(text, 1, true) then
          return finding.level
        end
      end
    end
  end

  ---Runs `check()` with `vim.health` recorded; returns the `{ fn, msg }` calls.
  local function checked()
    local calls, originals = {}, {}
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
    assert.is_true(ok, tostring(err))
    return calls
  end

  ---Level of the first `check()` call whose message contains `text`.
  local function checked_level(text)
    for _, call in ipairs(checked()) do
      if call[1] ~= "start" and call[2]:find(text, 1, true) then
        return call[1]
      end
    end
  end

  ---Runs `fn` with each module in `modules` forced to its state ("installed"/"absent"), then restores them.
  local function with_modules(modules, fn)
    local saved = {}
    for name, state in pairs(modules) do
      saved[name] = { package.loaded[name], package.preload[name] }
      package.loaded[name] = nil
      package.preload[name] = function()
        if state == "absent" then
          error("not installed")
        end
        return {}
      end
    end
    local ok, err = pcall(fn)
    for name, previous in pairs(saved) do
      package.loaded[name], package.preload[name] = previous[1], previous[2]
    end
    assert.is_true(ok, tostring(err))
  end

  it("reports the running Neovim when it is 0.12 or newer", function()
    assert.equal("ok", level({}, "Neovim 0.12.5"))
    assert.equal("error", level({ nvim_012 = false }, "Neovim 0.12 or newer is required"))
  end)

  it("reports git, and errors without it", function()
    assert.equal("ok", level({}, "`git` found"))
    assert.equal("error", level({ git = false }, "`git` not found"))
  end)

  it("reports gh, and warns without it", function()
    assert.equal("ok", level({}, "`gh` found"))
    assert.equal("warn", level({ gh = false }, "`gh` not found"))
  end)

  it("reports the icon provider, and warns without one", function()
    assert.equal("ok", level({}, "icons from `mini.icons`"))
    assert.equal("ok", level({ icons = "nvim-web-devicons" }, "icons from `nvim-web-devicons`"))
    assert.equal("warn", level({ icons = false }, "no icon provider"))
  end)

  it("reports which-key as ok when installed, info when not", function()
    assert.equal("ok", level({}, "`which-key` found"))
    assert.equal("info", level({ which_key = false }, "`which-key` not found"))
  end)

  it("reports mini.pick as ok only when installed and set up", function()
    assert.equal("info", level({ mini_pick = false }, "`mini.pick` not found"))
    assert.equal("info", level({ mini_pick = "installed" }, "`mini.pick` is installed but not set up"))
    assert.equal("ok", level({}, "`mini.pick` found"))
  end)

  it("errors on a missing gitsigns only while PR Review Mode is enabled", function()
    assert.equal("ok", level({}, "`gitsigns` found"))
    assert.equal("info", level({ gitsigns = false }, "`gitsigns` not found"))
    local review = vim.tbl_deep_extend("force", config.get(), { pr_review = { enabled = true } })
    assert.equal("error", level({ gitsigns = false, options = review }, "`gitsigns` not found"))
  end)

  it("names the language servers that provide symbols", function()
    assert.equal("info", level({ symbol_servers = {} }, "no attached language server"))
    assert.equal("info", level({}, "`textDocument/documentSymbol` from lua_ls"))
  end)

  it("reports each test-symbol parser, and notes a missing one", function()
    local parsers = { { lang = "rust", found = false }, { lang = "tsx", found = true } }
    assert.equal("info", level({ parsers = parsers }, "no treesitter parser for `rust`"))
    assert.equal("ok", level({ parsers = parsers }, "treesitter parser for `tsx`"))
  end)

  it("shows the options in force", function()
    assert.equal("info", level({}, "min_file_width"))
  end)

  it("probes each parser the test-symbol marker needs", function()
    local original_languages = attributes.languages
    attributes.languages = function()
      return { "changeset_no_such_lang", "lua" }
    end
    local ok, err = pcall(function()
      assert.equal("info", checked_level("no treesitter parser for `changeset_no_such_lang`"))
      assert.equal("ok", checked_level("treesitter parser for `lua` found"))
    end)
    attributes.languages = original_languages
    assert.is_true(ok, tostring(err))
  end)

  it("probes optional plugins by loading them", function()
    local original_mini_pick = MiniPick
    local ok, err = pcall(function()
      with_modules({ ["which-key"] = "installed", gitsigns = "absent", ["mini.pick"] = "absent" }, function()
        assert.equal("ok", checked_level("`which-key` found"))
        assert.equal("info", checked_level("`gitsigns` not found"))
        assert.equal("info", checked_level("`mini.pick` not found"))
      end)
      with_modules({ ["mini.pick"] = "installed" }, function()
        MiniPick = nil
        assert.equal("info", checked_level("`mini.pick` is installed but not set up"))
        MiniPick = {}
        assert.equal("ok", checked_level("`mini.pick` found and set up"))
      end)
    end)
    MiniPick = original_mini_pick
    assert.is_true(ok, tostring(err))
  end)

  it("names only the servers that provide documentSymbol, once each", function()
    local original_get_clients = vim.lsp.get_clients
    vim.lsp.get_clients = function(opts)
      if opts and opts.method == "textDocument/documentSymbol" then
        return { { name = "lua_ls" }, { name = "lua_ls" } }
      end
      return {}
    end
    local ok, calls = pcall(checked)
    vim.lsp.get_clients = original_get_clients
    assert.is_true(ok, tostring(calls))
    local symbols_call = vim.iter(calls):find(function(call)
      return call[2]:find("textDocument/documentSymbol", 1, true) ~= nil
    end)
    assert.equal("`textDocument/documentSymbol` from lua_ls", symbols_call[2])
  end)

  it("calls no process or server API itself", function()
    local targets = {
      { "vim.system", vim, "system" },
      { "vim.fn.system", vim.fn, "system" },
      { "vim.fn.jobstart", vim.fn, "jobstart" },
      { "vim.lsp.start", vim.lsp, "start" },
      { "vim.lsp.enable", vim.lsp, "enable" },
    }
    local calls, originals = {}, {}
    for i, target in ipairs(targets) do
      originals[i] = target[2][target[3]]
      target[2][target[3]] = function()
        table.insert(calls, target[1])
      end
    end
    local ok, err = pcall(checked)
    for i, target in ipairs(targets) do
      target[2][target[3]] = originals[i]
    end
    assert.is_true(ok, tostring(err))
    assert.same({}, calls)
  end)

  it("does not load the plugin's entry module", function()
    checked()
    assert.is_nil(package.loaded["changeset"])
  end)

  it("check() starts each section in order and emits only health levels", function()
    local starts = {}
    for _, call in ipairs(checked()) do
      if call[1] == "start" then
        table.insert(starts, call[2])
      else
        assert.is_true(vim.list_contains({ "ok", "warn", "error", "info" }, call[1]), call[1])
      end
    end
    assert.same({ "Requirements", "Optional integrations", "Configuration" }, starts)
  end)
end)
