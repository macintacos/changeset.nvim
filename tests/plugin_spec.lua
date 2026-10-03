---The changeset augroups that hold an autocmd.
---@return table<string, true>
local function changeset_groups()
  local groups = {}
  for _, autocmd in ipairs(vim.api.nvim_get_autocmds({})) do
    local name = autocmd.group_name
    if type(name) == "string" and vim.startswith(name, "changeset.") then
      groups[name] = true
    end
  end
  return groups
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

-- The cases run in order: the first real `require("changeset.build")` is the last case's,
-- since its autocmds outlive it and the first case asserts there are none.
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
    assert.same({ ["changeset.plugin"] = true }, changeset_groups())
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
    assert.same({ "pr", "refresh", "review", "toggle" }, vim.fn.getcompletion("Changeset ", "cmdline"))
    assert.same({ "refresh", "review" }, vim.fn.getcompletion("Changeset re", "cmdline"))
  end)

  it("routes each subcommand to the module, bare :Changeset to toggle", function()
    local calls = {}
    package.loaded.changeset = { toggle = counter(calls, "toggle") }
    package.loaded["changeset.build"] = { refresh = counter(calls, "refresh") }

    vim.cmd("Changeset")
    vim.cmd("Changeset toggle ")
    vim.cmd("Changeset refresh")

    package.loaded.changeset = nil
    package.loaded["changeset.build"] = nil
    assert.same({ toggle = 2, refresh = 1 }, calls)
  end)

  it("routes <Plug>(changeset-toggle) to toggle", function()
    local calls = {}
    package.loaded.changeset = { toggle = counter(calls, "toggle") }

    vim.api.nvim_feedkeys(vim.keycode("<Plug>(changeset-toggle)"), "x", false)

    package.loaded.changeset = nil
    assert.equal(1, calls.toggle)
  end)

  it("runs the command after a | once the subcommand ran", function()
    local calls = {}
    package.loaded["changeset.build"] = { refresh = counter(calls, "refresh") }

    vim.cmd("Changeset refresh | let g:changeset_after = 1")

    package.loaded["changeset.build"] = nil
    assert.equal(1, calls.refresh)
    assert.equal(1, vim.g.changeset_after)
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

  it("completes pr's verbs that match the argument", function()
    assert.same({ "abandon", "comment", "delete", "start", "submit" }, vim.fn.getcompletion("Changeset pr ", "cmdline"))
    assert.same({ "start", "submit" }, vim.fn.getcompletion("Changeset pr s", "cmdline"))
    assert.same({ "start", "submit" }, vim.fn.getcompletion("silent Changeset pr s", "cmdline"))
    assert.same({}, vim.fn.getcompletion("Changeset toggle ", "cmdline"))
    assert.same(
      { "abandon", "comment", "delete", "start", "submit" },
      vim.fn.getcompletion("redraw | Changeset pr ", "cmdline")
    )
    assert.same({ "pr", "refresh", "review", "toggle" }, vim.fn.getcompletion("1,2Changeset ", "cmdline"))
  end)

  it("routes each pr verb to the pr module", function()
    local calls = {}
    package.loaded["changeset.pr"] = {
      start = counter(calls, "start"),
      abandon = counter(calls, "abandon"),
      delete = counter(calls, "delete"),
      submit = counter(calls, "submit"),
    }

    vim.cmd("Changeset pr start")
    vim.cmd("Changeset pr abandon")
    vim.cmd("Changeset pr delete")
    vim.cmd("Changeset pr submit")
    vim.cmd("Changeset pr start | let g:changeset_pr_after = 1")

    package.loaded["changeset.pr"] = nil
    assert.same({ start = 2, abandon = 1, delete = 1, submit = 1 }, calls)
    assert.equal(1, vim.g.changeset_pr_after)
  end)

  it("routes pr comment the lines it is given", function()
    local ranges, calls = {}, {}
    package.loaded["changeset.pr"] = {
      comment = function(first, last)
        table.insert(ranges, { first, last })
      end,
      start = counter(calls, "start"),
    }
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(("x"):rep(10, "\n"), "\n"))
    vim.api.nvim_win_set_cursor(0, { 3, 0 })

    vim.cmd("Changeset pr comment")
    vim.cmd("2,4Changeset pr comment")
    vim.cmd("normal! 2GVj\27")
    vim.cmd("'<,'>Changeset pr comment")
    vim.cmd("1Changeset pr start")

    vim.api.nvim_buf_delete(buf, { force = true })
    package.loaded["changeset.pr"] = nil
    assert.same({ { 3, 3 }, { 2, 4 }, { 2, 3 } }, ranges)
    assert.same({ start = 1 }, calls)
  end)

  it("reports an unknown pr verb as an unknown subcommand", function()
    vim.cmd("Changeset pr bogus")

    assert.equal(1, #notes)
    assert.equal(vim.log.levels.ERROR, notes[1].level)
    assert.truthy(notes[1].msg:find("unknown subcommand pr bogus", 1, true))
  end)

  it("names pr's verbs when it is given none", function()
    vim.cmd("Changeset pr")

    assert.equal(1, #notes)
    assert.equal(vim.log.levels.ERROR, notes[1].level)
    assert.truthy(
      notes[1].msg:find("abandon", 1, true)
        and notes[1].msg:find("delete", 1, true)
        and notes[1].msg:find("start", 1, true)
    )
  end)

  it("reports words past a subcommand as an error", function()
    vim.cmd("Changeset toggle extra")

    assert.equal(1, #notes)
    assert.equal(vim.log.levels.ERROR, notes[1].level)
  end)

  it("loads the module on first use", function()
    package.loaded["changeset.build"] = nil

    vim.cmd("Changeset refresh")

    assert.truthy(package.loaded["changeset.build"])
  end)
end)
