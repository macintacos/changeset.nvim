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

---The stdout of a fresh headless Neovim that loads the plugin, runs `args` and, once startup is done, `probe`.
---@param args string[] More arguments, before the probe's.
---@param probe string Lua that writes its answer with io.write.
---@param wait_ms integer? How long the main loop runs, typed keys and all, before the probe.
---@return string
local function after_startup(args, probe, wait_ms)
  local root = vim.fn.fnamemodify(vim.api.nvim_get_runtime_file("plugin/changeset.lua", false)[1], ":h:h")
  local cmd = { vim.v.progpath, "--headless", "-u", "NONE", "--cmd", "set rtp^=" .. root }
  vim.list_extend(cmd, { "--cmd", "runtime plugin/changeset.lua" })
  vim.list_extend(cmd, args)
  vim.list_extend(cmd, {
    "--cmd",
    ("autocmd VimEnter * ++once lua vim.defer_fn(function() %s; vim.cmd('qa!') end, %d)"):format(probe, wait_ms or 0),
  })
  return vim.system(cmd):wait(10000).stdout
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
    assert.same(
      { "comment", "next", "prev", "refresh", "review", "toggle" },
      vim.fn.getcompletion("Changeset ", "cmdline")
    )
    assert.same({ "refresh", "review" }, vim.fn.getcompletion("Changeset re", "cmdline"))
  end)

  it("completes the verbs under a subcommand", function()
    assert.same(
      { "del", "last", "list", "new", "next", "prev", "toggle" },
      vim.fn.getcompletion("Changeset comment ", "cmdline")
    )
    assert.same({ "last", "list" }, vim.fn.getcompletion("'<,'>Changeset  comment  l", "cmdline"))
    assert.same({ "abandon", "mode", "submit", "yank" }, vim.fn.getcompletion("Changeset review ", "cmdline"))
    assert.same({}, vim.fn.getcompletion("Changeset toggle ", "cmdline"))
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

  it("names the verbs a subcommand takes when its verb is missing or unknown", function()
    vim.cmd("Changeset comment")
    vim.cmd("Changeset review bogus")

    assert.equal(2, #notes)
    assert.equal(vim.log.levels.ERROR, notes[1].level)
    assert.equal("Changeset: :Changeset comment takes a verb: del, last, list, new, next, prev, toggle", notes[1].msg)
    assert.equal(vim.log.levels.ERROR, notes[2].level)
    assert.equal("Changeset: :Changeset review takes a verb: abandon, mode, submit, yank", notes[2].msg)
  end)

  it("refuses review mode while pr_review.enabled is off", function()
    vim.cmd("Changeset review mode")

    assert.equal(1, #notes)
    assert.equal(vim.log.levels.ERROR, notes[1].level)
    assert.truthy(notes[1].msg:find("pr_review.enabled", 1, true))
    assert.is_nil(package.loaded["changeset.review"])
  end)

  it("toggles review mode once pr_review.enabled is on", function()
    local calls = {}
    require("changeset.config").setup({ pr_review = { enabled = true } })
    package.loaded["changeset.review"] = { toggle = counter(calls, "toggle") }

    vim.cmd("Changeset review mode")

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

  it("routes comment del and review abandon to the reviewing module", function()
    local calls = {}
    package.loaded["changeset.reviewing"] = { delete = counter(calls, "delete"), abandon = counter(calls, "abandon") }

    vim.cmd("Changeset comment  del")
    vim.cmd("Changeset review abandon | let g:changeset_after = 1")

    package.loaded["changeset.reviewing"] = nil
    assert.same({ delete = 1, abandon = 1 }, calls)
    assert.equal(1, vim.g.changeset_after)
  end)

  it("routes comment new the lines it is given, and the cursor's place without any", function()
    local ranges = {}
    package.loaded["changeset.reviewing"] = {
      comment = function(first, last)
        table.insert(ranges, { first, last })
      end,
      comment_here = function()
        table.insert(ranges, "here")
      end,
    }
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(("x"):rep(10, "\n"), "\n"))
    vim.api.nvim_win_set_cursor(0, { 3, 0 })

    vim.cmd("Changeset comment new")
    vim.cmd("2,4Changeset comment new")
    vim.cmd("normal! 2GVj\27")
    vim.cmd("'<,'>Changeset comment new")

    vim.api.nvim_buf_delete(buf, { force = true })
    package.loaded["changeset.reviewing"] = nil
    assert.same({ "here", { 2, 4 }, { 2, 3 } }, ranges)
  end)

  it("reports words past a subcommand as an error", function()
    vim.cmd("Changeset toggle extra")
    vim.cmd("Changeset comment new extra")

    assert.equal(2, #notes)
    assert.equal(vim.log.levels.ERROR, notes[1].level)
    assert.equal(vim.log.levels.ERROR, notes[2].level)
  end)

  it("loads the module on first use", function()
    package.loaded["changeset.build"] = nil

    vim.cmd("Changeset refresh")

    assert.truthy(package.loaded["changeset.build"])
  end)

  it("routes each <Plug> map to its subcommand", function()
    local calls = {}
    local plugs = {
      ["comment-new"] = "comment_here",
      ["comment-del"] = "delete",
      ["comment-last"] = "last_comment",
      ["comment-list"] = "list",
      ["review-yank"] = "yank",
      ["review-submit"] = "submit",
      ["review-abandon"] = "abandon",
    }
    local reviewing = {}
    for _, fn in pairs(plugs) do
      reviewing[fn] = counter(calls, fn)
    end
    package.loaded["changeset.reviewing"] = reviewing
    package.loaded["changeset.build"] = { refresh = counter(calls, "refresh") }
    require("changeset.config").setup({ pr_review = { enabled = true } })
    package.loaded["changeset.review"] = { toggle = counter(calls, "review") }
    package.loaded["changeset.review_comment_blocks"] = { toggle = counter(calls, "blocks") }

    for _, name in ipairs(vim.list_extend({ "refresh", "review-mode", "comment-toggle" }, vim.tbl_keys(plugs))) do
      vim.api.nvim_feedkeys(vim.keycode(("<Plug>(changeset-%s)"):format(name)), "x", false)
    end

    package.loaded["changeset.reviewing"] = nil
    package.loaded["changeset.build"] = nil
    package.loaded["changeset.review"] = nil
    package.loaded["changeset.review_comment_blocks"] = nil
    require("changeset.config").setup()
    for name, count in pairs(calls) do
      assert.equal(1, count, name)
    end
  end)

  describe("the stepping maps", function()
    local steps, buf

    ---Stubs the stepping functions to record `{ name, count }` and switch to a fresh buffer, as a jump does.
    before_each(function()
      steps = {}
      local function record(name)
        return function(count)
          table.insert(steps, { name, count })
          vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(false, true))
        end
      end
      package.loaded.changeset = { step = record("step") }
      package.loaded["changeset.reviewing"] = {
        next_comment = record("next_comment"),
        prev_comment = record("prev_comment"),
      }
      buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(buf)
    end)

    after_each(function()
      package.loaded.changeset = nil
      package.loaded["changeset.reviewing"] = nil
    end)

    it("step by their count, and . repeats them after the jump switched buffers", function()
      vim.api.nvim_feedkeys(vim.keycode("<Plug>(changeset-next)") .. "..", "x", false)
      vim.api.nvim_feedkeys("3" .. vim.keycode("<Plug>(changeset-prev)") .. ".", "x", false)
      vim.api.nvim_feedkeys(vim.keycode("<Plug>(changeset-comment-next)") .. ".", "x", false)
      vim.api.nvim_feedkeys("2" .. vim.keycode("<Plug>(changeset-comment-prev)") .. ".", "x", false)

      assert.same({
        { "step", 1 },
        { "step", 1 },
        { "step", 1 },
        { "step", -3 },
        { "step", -3 },
        { "next_comment", 1 },
        { "next_comment", 1 },
        { "prev_comment", 2 },
        { "prev_comment", 2 },
      }, steps)
    end)

    it("leave the buffer alone", function()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "keep" })
      vim.api.nvim_set_current_buf(buf)

      vim.api.nvim_feedkeys(vim.keycode("<Plug>(changeset-next)") .. ".", "x", false)

      assert.same({ "keep" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end)
  end)

  it("routes the visual <Plug>(changeset-comment-new) the selected lines", function()
    local ranges = {}
    package.loaded["changeset.reviewing"] = {
      comment = function(first, last)
        table.insert(ranges, { first, last })
      end,
    }
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(("x"):rep(10, "\n"), "\n"))

    vim.api.nvim_feedkeys("2GVj" .. vim.keycode("<Plug>(changeset-comment-new)"), "x", false)

    vim.api.nvim_buf_delete(buf, { force = true })
    package.loaded["changeset.reviewing"] = nil
    assert.same({ { 2, 3 } }, ranges)
  end)

  it("maps the default <C-g> keys once startup is done", function()
    local probe = "for _, lhs in ipairs({ 'cc', 'cd', 'cq', 'd', 'l', 's', 'n', 'm' }) do"
      .. " io.write(vim.fn.maparg('<C-g>' .. lhs, 'n'), ' ') end"
      .. " io.write(vim.fn.maparg('<C-g>cc', 'x'))"

    assert.equal(
      "<Plug>(changeset-comment-new) <Plug>(changeset-comment-del) <Plug>(changeset-comment-list)   "
        .. "<Plug>(changeset-review-submit) <Plug>(changeset-next) <Plug>(changeset-review-mode) <Plug>(changeset-comment-new)",
      after_startup({}, probe)
    )
  end)

  it("leaves a <C-g> key the user mapped alone", function()
    local probe = "io.write(vim.fn.maparg('<C-g>s', 'n'), ' ', vim.fn.maparg('<C-g>n', 'n'))"

    assert.equal(":echo 1<CR> <Plug>(changeset-next)", after_startup({ "-c", "nnoremap <C-g>s :echo 1<CR>" }, probe))
  end)

  it("maps a default key that only the startup buffer maps for itself", function()
    local probe = "for _, map in ipairs(vim.api.nvim_get_keymap('n')) do"
      .. " if map.lhs == '<C-G>n' then io.write(map.rhs) end end"

    assert.equal("<Plug>(changeset-next)", after_startup({ "-c", "nnoremap <buffer> <C-g>n :echo 1<CR>" }, probe))
  end)

  it("leaves a default key alone under a user's shorter or longer map", function()
    local probe = "io.write(vim.fn.maparg('<C-g>cc', 'n'), '|', vim.fn.maparg('<C-g>cc', 'x'))"

    assert.equal(
      "|",
      after_startup({ "-c", "nnoremap <C-g> :echo 1<CR>", "-c", "xnoremap <C-g>ccx :echo 1<CR>" }, probe)
    )
  end)

  it("leaves a user's own maps onto changeset's <Plug> maps alone", function()
    local probe =
      "io.write(vim.fn.maparg('<C-g>n', 'n'), ' ', vim.fn.maparg('<C-g>cn', 'n'), ' ', vim.fn.maparg('<C-g>cc', 'n'))"
    local args = { "-c", "nmap <C-g>n <Plug>(changeset-prev)", "-c", "nmap <C-g>cn <Plug>(changeset-comment-new)" }

    assert.equal(
      "<Plug>(changeset-prev) <Plug>(changeset-comment-new) <Plug>(changeset-comment-new)",
      after_startup(args, probe)
    )
  end)

  describe("a pause after <C-g>c", function()
    ---Types `keys` into ten numbered lines with `'timeoutlen'` short, then reports the comment's range, the mode and
    ---the lines.
    ---@param keys string
    ---@return string
    local function pause_after(keys)
      local typed = "lua vim.o.timeoutlen = 50;"
        .. " vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(('x'):rep(10, '\\n'), '\\n'));"
        .. " package.loaded['changeset.reviewing'] = {"
        .. " comment = function(a, b) io.write(a, '-', b, ' ') end,"
        .. " comment_here = function() io.write('here ') end };"
        .. (" vim.api.nvim_input('%s')"):format(keys)
      local probe =
        "io.write(vim.api.nvim_get_mode().mode, ' ', table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false)))"
      return after_startup({ "-c", typed }, probe, 400)
    end

    it("comments at the cursor in normal mode", function()
      assert.equal("here n xxxxxxxxxx", pause_after("3G<C-g>c"))
    end)

    it("comments on the selection in visual mode", function()
      assert.equal("3-4 n xxxxxxxxxx", pause_after("3GVj<C-g>c"))
    end)

    it("leaves <C-g>c alone when the user maps under it", function()
      local probe = "io.write(vim.fn.maparg('<C-g>c', 'n'))"

      assert.equal("", after_startup({ "-c", "nnoremap <C-g>cx :echo 1<CR>" }, probe))
    end)
  end)

  it("gives which-key a mini.icons icon for each default key it maps", function()
    local stub = "lua package.loaded['which-key'] = { add = function(spec) added = spec end }"
    local probe = "for _, spec in ipairs(added) do"
      .. " if vim.list_contains({ '<C-g>cc', '<C-g>cq', '<C-g>s' }, spec[1]) then"
      .. " io.write(spec.mode, spec[1], ' ', spec.icon.cat, '/', spec.icon.name, ' ') end end"

    assert.equal(
      "n<C-g>cc filetype/messages x<C-g>cc filetype/messages n<C-g>cq filetype/qf ",
      after_startup({ "-c", stub, "-c", "nnoremap <C-g>s :echo 1<CR>" }, probe)
    )
  end)

  it("maps no default keys when vim.g.changeset_no_default_maps is set", function()
    local probe = "io.write(vim.fn.maparg('<C-g>cc', 'n'), vim.fn.maparg('<C-g>cc', 'x'))"

    assert.equal("", after_startup({ "-c", "let g:changeset_no_default_maps = 1" }, probe))
  end)
end)
