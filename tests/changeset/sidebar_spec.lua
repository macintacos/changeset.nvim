local changeset = require("plugins.changeset")
local window = require("plugins.changeset.window")

local ns = vim.api.nvim_get_namespaces()["changeset"]

---Run git in the current directory, asserting it succeeded.
---@param args string[]
---@return string
local function git(args)
  local out = vim.fn.system(vim.list_extend({ "git" }, args))
  assert(vim.v.shell_error == 0, out)
  return vim.trim(out)
end

---@param path string
---@param lines string[]
local function write(path, lines)
  vim.fn.writefile(lines, path)
end

---A repo on `trunk` with two files, then a `feature` branch that changes both.
local function init_repo()
  git({ "init", "-q", "-b", "trunk" })
  -- Refuse to go further unless git resolved to the fixture. Everything below
  -- writes commits and config, and a stray GIT_* var pointing elsewhere would
  -- land them in a real repo.
  local root = vim.fn.resolve(git({ "rev-parse", "--show-toplevel" }))
  assert(root == vim.fn.resolve(vim.fn.getcwd()), "fixture git repo escaped to " .. root)

  git({ "config", "user.email", "test@example.com" })
  git({ "config", "user.name", "Test" })
  git({ "config", "commit.gpgsign", "false" })

  write("mod.lua", { "local M = {}", "", "function M.one()", "  return 1", "end", "", "return M" })
  write("other.lua", { "return { a = 1 }" })
  git({ "add", "-A" })
  git({ "commit", "-q", "-m", "base" })

  git({ "checkout", "-q", "-b", "feature" })
  write("mod.lua", { "local M = {}", "", "function M.one()", "  return 2", "end", "", "return M" })
  write("other.lua", { "return { a = 1, b = 2 }" })
  git({ "add", "-A" })
  git({ "commit", "-q", "-m", "change" })
end

---@param buf integer
---@return string[]
local function lines_of(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---@return integer buf
local function open_sidebar()
  vim.cmd.edit("mod.lua")
  changeset.open()
  local buf
  vim.wait(10000, function()
    buf = window.buf()
    return buf and #lines_of(buf) > 1
  end, 25)
  assert(buf, "the sidebar never opened a buffer")

  -- Symbols land after the diff does, replacing each file's placeholder row with
  -- however many rows it really has. A count taken before that settles drifts on
  -- its own, and every assertion below compares counts.
  local settled = vim.wait(10000, function()
    return not table.concat(lines_of(buf), "\n"):find("reading symbols", 1, true)
  end, 25)
  assert(settled, "symbols never finished resolving")
  return buf
end

---@param key string
local function press(key)
  vim.api.nvim_set_current_win(window.win())
  vim.cmd.normal(key)
end

describe("changeset sidebar", function()
  local tmp, cwd, git_env, state_home

  before_each(function()
    -- Git hooks export GIT_DIR and friends, and those override cwd-based repo
    -- discovery — under `pre-push` the fixture below would otherwise operate on
    -- the repo being pushed.
    git_env = {}
    for name, value in pairs(vim.fn.environ()) do
      if name:match("^GIT_") then
        git_env[name] = value
        vim.env[name] = nil
      end
    end

    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    -- `prefs.path()` hangs off stdpath("state"), so without this the sidebar
    -- opens with whatever symbol kinds the developer has hidden in their own
    -- editor, and what this fixture renders changes machine to machine.
    state_home = vim.env.XDG_STATE_HOME
    vim.env.XDG_STATE_HOME = tmp .. "/state"

    cwd = vim.fn.chdir(tmp)
    assert(cwd ~= "", "could not enter the fixture directory")
    init_repo()
  end)

  after_each(function()
    changeset.close()
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(cwd)
    vim.fn.delete(tmp, "rf")
    vim.env.XDG_STATE_HOME = state_home
    for name, value in pairs(git_env) do
      vim.env[name] = value
    end
  end)

  it("lists every file the branch changed", function()
    local text = table.concat(lines_of(open_sidebar()), "\n")

    assert.truthy(text:find("mod.lua", 1, true))
    assert.truthy(text:find("other.lua", 1, true))
  end)

  it("marks the lines it rendered", function()
    local buf = open_sidebar()

    -- Counting row marks rather than every mark in the namespace: the hidden-kinds
    -- note is the one virtual line that lands here without a row behind it, and a
    -- bare count would pass on that alone.
    local row_marks = vim.tbl_filter(function(mark)
      return mark[4].virt_lines == nil
    end, vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }))

    assert.truthy(#row_marks > 0)
  end)

  it("summarises the branch in the window bar", function()
    open_sidebar()

    assert.truthy(vim.wo[window.win()].winbar:find("%d"))
  end)

  it("shuts every file, then opens them again", function()
    local buf = open_sidebar()
    local expanded = #lines_of(buf)

    press("H")
    local collapsed = #lines_of(buf)
    press("L")

    assert.truthy(collapsed < expanded)
    assert.equal(expanded, #lines_of(buf))
  end)

  ---Walk the selection `steps` rows with `]h`, commit it, and assert the previews
  ---left the jumplist alone while `<CR>` pointed `<C-o>` at the pre-sidebar position.
  ---@param steps integer
  local function commit_after(steps)
    vim.cmd.edit("mod.lua")
    local target = vim.api.nvim_get_current_win()
    local from_buf = vim.api.nvim_win_get_buf(target)
    local from_lnum = vim.api.nvim_win_get_cursor(target)[1]
    open_sidebar()
    local before = vim.fn.getjumplist(target)[1]

    for _ = 1, steps do
      vim.cmd.normal("]h")
    end

    assert.same(before, vim.fn.getjumplist(target)[1])
    assert.equal(target, vim.api.nvim_get_current_win())
    -- The band is the proof a preview landed at all: without it an untouched
    -- jumplist would also pass when `]h` did nothing.
    assert.truthy(vim.wo[target].winbar ~= "")

    vim.api.nvim_set_current_win(window.win())
    vim.cmd.normal(vim.keycode("<CR>"))

    local jumps = vim.fn.getjumplist(target)[1]
    local last_jump = jumps[#jumps]
    assert.truthy(last_jump, "<CR> recorded no jumplist entry, so <C-o> has nowhere to go")
    assert.equal(from_buf, last_jump.bufnr)
    assert.equal(from_lnum, last_jump.lnum)
  end

  it("previews without touching the jumplist, and sends <C-o> back to where the sidebar opened", function()
    commit_after(3)
  end)

  -- One `]h` stays inside the file the sidebar was opened from, where the commit
  -- re-shows the buffer the window already holds, so no buffer swap records the
  -- jump and the commit has to.
  it("sends <C-o> back for a row in the file the sidebar was opened from", function()
    commit_after(1)
  end)

  it("shuts the row under the cursor", function()
    local buf = open_sidebar()
    local expanded = #lines_of(buf)

    press("h")

    assert.truthy(#lines_of(buf) < expanded)
  end)
end)
