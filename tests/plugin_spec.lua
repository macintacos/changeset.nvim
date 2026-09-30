local GROUPS = { "changeset.highlights", "changeset.track", "changeset.unband", "changeset.servers", "changeset.watch" }

---Whether the autocmd group exists.
---@param name string
---@return boolean
local function group_exists(name)
  return (pcall(vim.api.nvim_get_autocmds, { group = name }))
end

---A function that counts its calls in `calls[key]`.
---@param calls table<string, integer>
---@param key string
---@return function
local function counter(calls, key)
  calls[key] = 0
  return function()
    calls[key] = calls[key] + 1
  end
end

-- The cases run in order: the first real `require("changeset")` is the last case's,
-- and once loaded its autocmds stay for the session.
describe("plugin/changeset.lua", function()
  local notify, notes

  before_each(function()
    notify, notes = vim.notify, {}
    vim.notify = function(msg, level)
      table.insert(notes, { msg = msg, level = level })
    end
  end)

  after_each(function()
    vim.notify = notify
  end)

  it("loads no changeset module at startup", function()
    MiniPick = { registry = {} }
    vim.cmd("runtime plugin/changeset.lua")
    vim.api.nvim_exec_autocmds("VimEnter", {})
    vim.api.nvim_exec_autocmds("SessionLoadPost", {})

    assert.is_nil(package.loaded.changeset)
    assert.is_nil(package.loaded["changeset.pick"])
    assert.equal(1, #vim.api.nvim_get_autocmds({ group = "changeset.plugin", event = "SessionLoadPost" }))
    for _, name in ipairs(GROUPS) do
      assert.is_false(group_exists(name), name)
    end
  end)

  it("registers a mini.pick source that opens the changeset picker", function()
    local calls = {}
    package.loaded["changeset.pick"] = { pick = counter(calls, "pick") }

    assert.is_function(MiniPick.registry.changeset)
    MiniPick.registry.changeset()

    package.loaded["changeset.pick"] = nil
    assert.equal(1, calls.pick)
  end)

  it("registers the mini.pick source when loaded after startup", function()
    local root = vim.fn.fnamemodify(vim.api.nvim_get_runtime_file("plugin/changeset.lua", false)[1], ":h:h")
    local probe = "autocmd VimEnter * ++once lua vim.schedule(function() vim.cmd('runtime plugin/changeset.lua');"
      .. " io.write(type(MiniPick.registry.changeset)); vim.cmd('qa!') end)"
    local result = vim
      .system({
        vim.v.progpath,
        "--headless",
        "-u",
        "NONE",
        "--cmd",
        "set rtp^=" .. root,
        "--cmd",
        "lua MiniPick = { registry = {} }",
        "--cmd",
        probe,
      })
      :wait(10000)

    assert.equal("function", result.stdout)
  end)

  it("completes the subcommands that match the argument", function()
    assert.same({ "refresh", "review", "toggle" }, vim.fn.getcompletion("Changeset ", "cmdline"))
    assert.same({ "refresh", "review" }, vim.fn.getcompletion("Changeset re", "cmdline"))
  end)

  it("routes toggle and refresh to the module", function()
    local calls = {}
    package.loaded.changeset = { toggle = counter(calls, "toggle"), refresh = counter(calls, "refresh") }

    vim.cmd("Changeset")
    vim.cmd("Changeset toggle")
    vim.api.nvim_feedkeys(vim.keycode("<Plug>(changeset-toggle)"), "x", false)
    vim.cmd("Changeset refresh")
    vim.cmd("Changeset toggle ")
    vim.cmd("Changeset refresh | let g:changeset_after = 1")
    local map = vim.fn.maparg("<Plug>(changeset-toggle)", "n", false, true)

    package.loaded.changeset = nil
    assert.equal(4, calls.toggle)
    assert.equal(2, calls.refresh)
    assert.equal(1, vim.g.changeset_after)
    assert.truthy(map.desc)
  end)

  it("reports an unknown subcommand as an error", function()
    vim.cmd("Changeset bogus")

    assert.equal(1, #notes)
    assert.equal(vim.log.levels.ERROR, notes[1].level)
  end)

  it("refuses review while pr_review.enabled is off", function()
    vim.cmd("Changeset review")

    assert.equal(1, #notes)
    assert.equal(vim.log.levels.ERROR, notes[1].level)
    assert.truthy(notes[1].msg:find("pr_review.enabled", 1, true))
    assert.is_nil(package.loaded["changeset.review"])
  end)

  it("toggles review once pr_review.enabled is on", function()
    local calls = {}
    require("changeset.config").setup({ pr_review = { enabled = true } })
    package.loaded["changeset.review"] = { toggle = counter(calls, "toggle") }

    vim.cmd("Changeset review")

    package.loaded["changeset.review"] = nil
    require("changeset.config").setup()
    assert.equal(1, calls.toggle)
  end)

  it("refills a sidebar window a session left behind", function()
    local calls = {}
    package.loaded.changeset = { restore = counter(calls, "restore") }
    local leftover = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(leftover, "changeset://tree")
    local win = vim.api.nvim_open_win(leftover, false, { split = "right", win = -1, width = 44 })

    vim.api.nvim_exec_autocmds("SessionLoadPost", {})

    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(leftover, { force = true })
    package.loaded.changeset = nil
    assert.equal(1, calls.restore)
  end)

  it("loads the module on first use", function()
    package.loaded.changeset = nil

    vim.cmd("Changeset refresh")

    assert.truthy(package.loaded.changeset)
    for _, name in ipairs(GROUPS) do
      assert.is_true(group_exists(name), name)
    end
  end)
end)
