describe("changeset.health", function()
  local health = require("changeset.health")
  local config = require("changeset.config")
  local attributes = require("changeset.attributes")

  local HEALTHY = {
    version = "0.12.5",
    nvim_012 = true,
    git = true,
    gh = true,
    herdr = true,
    icons = "mini.icons",
    which_key = true,
    mini_pick = "set up",
    gitsigns = true,
    gitsigns_unified = true,
    symbol_servers = { "lua_ls" },
    parsers = { { lang = "rust", found = true } },
    options = config.get(),
    unknown_options = {},
  }

  ---Level of the first finding, in report order, whose message contains `text`.
  ---@return string?
  local function level(overrides, text)
    local facts = vim.tbl_extend("force", HEALTHY, overrides)
    ---@cast facts changeset.health.Facts
    for _, section in ipairs(health._report(facts)) do
      for _, finding in ipairs(section.findings) do
        if finding.msg:find(text, 1, true) then
          return finding.level
        end
      end
    end
  end

  ---Runs `check()` with `vim.health` recorded; returns the `{ fn, msg }` calls.
  ---@return table
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
  ---@return string?
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

  it("reports the running Neovim on one too old for the rest of the check", function()
    local list = vim.list
    vim.list = nil
    local ok, result = pcall(checked_level, "Neovim")
    vim.list = list

    assert.is_true(ok, tostring(result))
    assert.truthy(result)
  end)

  it("reports git, and errors without it", function()
    assert.equal("ok", level({}, "`git` found"))
    assert.equal("error", level({ git = false }, "`git` not found"))
  end)

  it("reports gh, and warns without it", function()
    assert.equal("ok", level({}, "`gh` found"))
    assert.equal("warn", level({ gh = false }, "`gh` not found"))
  end)

  it("says whether :Changeset submit has herdr agents to paste into", function()
    assert.equal("ok", level({}, "running inside herdr"))
    assert.equal("warn", level({ herdr = false }, "not inside a herdr pane"))
  end)

  it("probes herdr from its workspace variable and executable", function()
    local saved = vim.env.HERDR_WORKSPACE_ID
    vim.env.HERDR_WORKSPACE_ID = nil
    local outside = checked_level("herdr")
    vim.env.HERDR_WORKSPACE_ID = ""
    local empty = checked_level("herdr")
    vim.env.HERDR_WORKSPACE_ID = saved
    assert.equal("warn", outside)
    assert.equal("warn", empty)
  end)

  it("reports the icon provider, and warns without one", function()
    assert.equal("ok", level({}, "icons from `mini.icons`"))
    assert.equal("ok", level({ icons = "nvim-web-devicons" }, "icons from `nvim-web-devicons`"))
    assert.equal("warn", level({ icons = false }, "no icon provider"))
    assert.equal("warn", level({ icons = "installed" }, "`mini.icons` is installed but not set up"))
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

  it("reports a missing gitsigns as info, since the gutter's base and the unified diff need it", function()
    assert.equal("ok", level({}, "`gitsigns` found"))
    assert.equal("info", level({ gitsigns = false }, "the gutter's branch base and the unified diff are unavailable"))
  end)

  it("tells a gitsigns too old for the unified diff from a current one", function()
    assert.equal("info", level({ gitsigns_unified = false }, "`gitsigns` has no unified view"))
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

  it("warns about the options setup() didn't know, and leaves them out of those in force", function()
    config.setup({ keymaps = { next = "]h" } })
    local ok, calls = pcall(checked)
    config.setup()
    assert.is_true(ok, tostring(calls))
    ---@cast calls table

    local warned = vim.iter(calls):find(function(call)
      return call[1] == "warn" and call[2]:find("keymaps.next", 1, true) ~= nil
    end)
    assert.not_nil(warned)
    local dumped = vim.iter(calls):find(function(call)
      return call[2]:find("min_file_width", 1, true) ~= nil
    end)
    assert.falsy(dumped[2]:find("]h", 1, true))
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
    ---@param value table?
    local function set_mini_pick(value)
      -- The probe reads MiniPick as a global, so the spec swaps that global itself.
      -- selene: allow(global_usage)
      rawset(_G, "MiniPick", value)
    end
    local original_mini_pick = MiniPick
    local ok, err = pcall(function()
      with_modules({ ["which-key"] = "installed", gitsigns = "absent", ["mini.pick"] = "absent" }, function()
        assert.equal("ok", checked_level("`which-key` found"))
        assert.equal("info", checked_level("`gitsigns` not found"))
        assert.equal("info", checked_level("`mini.pick` not found"))
      end)
      with_modules({ ["mini.pick"] = "installed" }, function()
        set_mini_pick(nil)
        assert.equal("info", checked_level("`mini.pick` is installed but not set up"))
        set_mini_pick({})
        assert.equal("ok", checked_level("`mini.pick` found and set up"))
      end)
    end)
    set_mini_pick(original_mini_pick)
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
    ---@cast calls table
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

  it("check() files each finding under its section's heading", function()
    local heading, findings = 0, {}
    for _, call in ipairs(checked()) do
      if call[1] == "start" then
        heading = heading + 1
      else
        findings[#findings + 1] = { msg = call[2], heading = heading }
      end
    end

    ---The heading, counted from 1, that the first finding mentioning `text` sits under.
    local function heading_of(text)
      for _, finding in ipairs(findings) do
        if finding.msg:find(text, 1, true) then
          return finding.heading
        end
      end
      error("no finding mentions " .. text)
    end
    assert.equal(1, heading_of("Neovim"))
    assert.equal(2, heading_of("`gh`"))
    assert.equal(3, heading_of("min_file_width"))
  end)
end)
