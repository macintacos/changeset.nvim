local support = require("support.git")

local data = vim.fn.stdpath("data") .. "/site/pack/"
vim.opt.rtp:prepend(vim.fn.glob(data .. "*/opt/gitsigns.nvim", false, true)[1])

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
-- The plugin file registers an un-grouped autocmd and keeps its state at file
-- scope, so it is sourced once. `want`, `toplevel`, `ours` and `moving` are tied
-- to a fixture repo each teardown deletes, so they own nothing in the next case;
-- `dismissed` and the branch memo `applied` persist, so each case opens its
-- first buffer on a branch other than the one the case before it ended on. A gh
-- lookup still in flight is dropped by the next case's first apply.
local pack_add = vim.pack.add
vim.pack.add = function() end
local ok, err = pcall(dofile, root .. "/plugin/gitsigns.lua")
vim.pack.add = pack_add
assert(ok, err)

require("support.gh")

local Obj = require("gitsigns.git").Obj
local in_flight, moves = 0, 0
local change_revision = Obj.change_revision
Obj.change_revision = function(...)
  in_flight, moves = in_flight + 1, moves + 1
  local result = change_revision(...)
  in_flight = in_flight - 1
  return result
end

---@param buf integer
---@return string? revision nil both before gitsigns caches the buffer and on the
---index, so await the cache before awaiting nil.
local function revision(buf)
  local bcache = require("gitsigns.cache").cache[buf]
  return bcache and bcache.git_obj.revision
end

---@param bufs integer[]
---@param pred fun(buf: integer): boolean
---@param timeout integer
---@return boolean
local function await_all(bufs, pred, timeout)
  return vim.wait(timeout, function()
    for _, buf in ipairs(bufs) do
      if not pred(buf) then
        return false
      end
    end
    return true
  end, 20)
end

---@param bufs integer[]
---@param want string?
---@param timeout integer
---@return boolean
local function await(bufs, want, timeout)
  return await_all(bufs, function(buf)
    return revision(buf) == want
  end, timeout)
end

---@param bufs integer[]
---@return boolean
local function await_cached(bufs)
  return await_all(bufs, function(buf)
    return require("gitsigns.cache").cache[buf] ~= nil
  end, 5000)
end

---Wait until no base change has been in flight for 200 ms.
---@return boolean
local function settle()
  local quiet_since
  return vim.wait(10000, function()
    if in_flight > 0 then
      quiet_since = nil
      return false
    end
    quiet_since = quiet_since or vim.uv.hrtime()
    return vim.uv.hrtime() - quiet_since >= 200e6
  end, 20)
end

---@param files string[]
---@return integer[]
local function edit(files)
  local bufs = {}
  for _, name in ipairs(files) do
    vim.cmd.edit(name)
    bufs[#bufs + 1] = vim.api.nvim_get_current_buf()
  end
  return bufs
end

describe("PR Review Mode", function()
  local dir, cwd, notify, change_base
  ---@type { msg: string, level: integer? }[]
  local notices

  ---A repo on `main` with `files` committed, and `branch` carrying a change to each.
  ---@param branch string
  ---@param files string[]
  local function fixture(branch, files)
    for _, name in ipairs(files) do
      vim.fn.writefile({ "one" }, dir .. "/" .. name)
    end
    support.commit("base", dir)
    support.git({ "switch", "-q", "-c", branch }, dir)
    for _, name in ipairs(files) do
      vim.fn.writefile({ "one", "two" }, dir .. "/" .. name)
    end
    support.commit("change", dir)
  end

  ---`fixture`'s repo with `a.txt` changed on `parent`, then again on `child` cut from it.
  ---@param child string
  local function stack(child)
    fixture("parent", { "a.txt" })
    support.git({ "switch", "-q", "-c", child }, dir)
    vim.fn.writefile({ "one", "two", "three" }, dir .. "/a.txt")
    support.commit("child change", dir)
  end

  ---@param branch string?
  ---@return string
  local function merge_base(branch)
    return support.git({ "merge-base", "HEAD", branch or "main" }, dir)
  end

  before_each(function()
    cwd = vim.fn.getcwd()
    dir = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(dir, "p")
    support.init_repo("main", dir)
    vim.o.hidden = true
    notices = {}
    notify = vim.notify
    vim.notify = function(msg, level)
      notices[#notices + 1] = { msg = msg, level = level }
    end
    change_base = require("gitsigns").change_base
  end)

  after_each(function()
    -- Let every base change in flight land before its repo is deleted under it.
    assert(settle(), "a base change never landed")
    vim.cmd("silent! %bwipeout!")
    -- The next fixture is another repo, where this one's merge base does not exist
    -- and every attach against it would fail.
    require("gitsigns").reset_base(true)
    vim.fn.chdir(cwd)
    vim.fn.delete(dir, "rf")
    vim.env.FAKE_GH_PR = nil
    vim.env.FAKE_GH_DELAY = nil
    vim.notify = notify
    require("gitsigns").change_base = change_base
  end)

  ---Every "on" notice, awaiting the first for up to `timeout` and a duplicate for a second.
  ---@param timeout integer
  ---@return string[]
  local function on_notices(timeout)
    local function on()
      return vim.tbl_filter(
        function(msg)
          return msg:match(": on ") ~= nil
        end,
        vim.tbl_map(function(n)
          return n.msg
        end, notices)
      )
    end
    vim.wait(timeout, function()
      return #on() > 0
    end, 20)
    vim.wait(1000, function()
      return #on() > 1
    end, 20)
    return on()
  end

  it("announces the PR's target branch once when toggled on", function()
    stack("stacked-announced")
    vim.env.FAKE_GH_PR = '{"baseRefName":"parent","state":"OPEN"}'
    vim.fn.chdir(dir)
    local bufs = edit({ "a.txt" })
    assert.is_true(await(bufs, merge_base("parent"), 5000))
    vim.cmd.PRReview()
    assert.is_true(await(bufs, nil, 5000))

    vim.cmd.PRReview()

    local on = on_notices(5000)
    assert.equal(1, #on)
    assert.matches("vs parent", on[1])
  end)

  it("announces no success when the default-branch base fails to apply", function()
    fixture("announce-failed", { "a.txt" })
    vim.fn.chdir(dir)
    local bufs = edit({ "a.txt" })
    assert.is_true(await(bufs, merge_base(), 5000))
    vim.cmd.PRReview()
    assert.is_true(await(bufs, nil, 5000))
    assert.is_true(settle())
    require("gitsigns").change_base = function(_, _, cb)
      vim.schedule(function()
        cb("boom")
      end)
    end

    vim.cmd.PRReview()

    assert.is_true(vim.wait(5000, function()
      return vim.iter(notices):any(function(n)
        return n.level == vim.log.levels.ERROR
      end)
    end, 20))
    assert.same({}, on_notices(1000))
  end)

  it("diffs a stacked branch against its PR's target branch", function()
    stack("stacked")
    vim.env.FAKE_GH_PR = '{"baseRefName":"parent","state":"OPEN"}'
    vim.fn.chdir(dir)

    local bufs = edit({ "a.txt" })

    assert.is_true(await(bufs, merge_base("parent"), 5000))
  end)

  it("keeps the default-branch base when the PR is not open", function()
    stack("stacked-merged")
    vim.env.FAKE_GH_PR = '{"baseRefName":"parent","state":"MERGED"}'
    vim.fn.chdir(dir)

    local bufs = edit({ "a.txt" })
    local base = merge_base()

    assert.is_true(await(bufs, base, 5000))
    assert.is_true(settle())
    assert.equal(base, revision(bufs[1]))
  end)

  it("drops a PR lookup that a toggle superseded", function()
    stack("stacked-toggled")
    vim.env.FAKE_GH_PR = '{"baseRefName":"parent","state":"OPEN"}'
    vim.env.FAKE_GH_DELAY = "1"
    vim.fn.chdir(dir)

    local bufs = edit({ "a.txt" })
    assert.is_true(await(bufs, merge_base(), 5000))
    vim.cmd.PRReview()
    assert.is_true(await(bufs, nil, 5000))

    assert.is_false(vim.wait(1500, function()
      return revision(bufs[1]) ~= nil
    end, 20))
  end)

  it("diffs a single edited file against the merge base", function()
    fixture("single", { "a.txt" })
    vim.fn.chdir(dir)

    local bufs = edit({ "a.txt" })

    assert.is_true(await(bufs, merge_base(), 5000))
  end)

  it("gives every buffer loaded in the same tick the merge base", function()
    fixture("burst", { "a.txt", "b.txt", "c.txt" })
    vim.fn.chdir(dir)

    local bufs = edit({ "a.txt", "b.txt", "c.txt" })

    assert.is_true(await(bufs, merge_base(), 5000))
  end)

  it("moves attached buffers to the new merge base after an external branch switch", function()
    local files = { "a.txt", "b.txt", "c.txt", "d.txt" }
    fixture("switched", files)
    support.git({ "switch", "-q", "main" }, dir)
    vim.fn.chdir(dir)

    local bufs = edit(files)
    assert.is_true(await_cached(bufs))

    support.git({ "switch", "-q", "switched" }, dir)

    assert.is_true(await(bufs, merge_base(), 10000))
  end)

  it("keeps a lone buffer on the merge base after an external branch switch", function()
    vim.fn.chdir(dir)
    for i = 1, 5 do
      vim.fn.writefile({ "base " .. i }, dir .. "/a.txt")
      support.commit("base " .. i, dir)
      support.git({ "switch", "-q", "-c", "lone-" .. i }, dir)
      vim.fn.writefile({ "base " .. i, "change" }, dir .. "/a.txt")
      support.commit("change " .. i, dir)
      support.git({ "switch", "-q", "main" }, dir)

      local bufs = edit({ "a.txt" })
      assert.is_true(await_cached(bufs))
      assert.is_true(await(bufs, nil, 5000))

      support.git({ "switch", "-q", "lone-" .. i }, dir)
      local base = merge_base()
      assert.is_true(await(bufs, base, 10000), "iteration " .. i)
      assert.is_false(vim.wait(500, function()
        return revision(bufs[1]) ~= base
      end, 20))

      vim.cmd("silent! %bwipeout!")
      support.git({ "switch", "-q", "main" }, dir)
    end
  end)

  it("leaves a base set by hand alone", function()
    vim.fn.writefile({ "one" }, dir .. "/a.txt")
    vim.fn.writefile({ "one" }, dir .. "/b.txt")
    support.commit("base", dir)
    local parent = support.git({ "rev-parse", "HEAD~1" }, dir)
    vim.fn.chdir(dir)

    local bufs = edit({ "a.txt", "b.txt" })
    assert.is_true(await_cached(bufs))
    vim.api.nvim_buf_call(bufs[1], function()
      require("gitsigns").change_base(parent)
    end)
    assert.is_true(await({ bufs[1] }, parent, 5000))

    vim.api.nvim_buf_set_lines(bufs[2], 0, -1, false, { "edited" })

    assert.is_false(vim.wait(1500, function()
      return revision(bufs[1]) ~= parent
    end, 20))
  end)

  it("leaves a base set by hand alone while the mode toggles", function()
    fixture("toggled", { "a.txt", "b.txt" })
    local tip = support.git({ "rev-parse", "HEAD" }, dir)
    vim.fn.chdir(dir)
    local bufs = edit({ "a.txt", "b.txt" })
    local base = merge_base()
    assert.is_true(await(bufs, base, 5000))
    vim.api.nvim_buf_call(bufs[1], function()
      require("gitsigns").change_base(tip)
    end)
    assert.is_true(await({ bufs[1] }, tip, 5000))

    vim.cmd.PRReview()
    assert.is_true(await({ bufs[2] }, nil, 5000))
    vim.cmd.PRReview()
    assert.is_true(await({ bufs[2] }, base, 5000))

    assert.is_true(settle())
    assert.equal(tip, revision(bufs[1]))
  end)

  it("leaves buffers from another repository alone", function()
    local other = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(other, "p")
    support.init_repo("main", other)
    vim.fn.writefile({ "one" }, other .. "/x.txt")
    support.commit("base", other)
    fixture("scoped", { "a.txt" })
    support.git({ "switch", "-q", "main" }, dir)
    vim.fn.chdir(dir)

    local bufs = edit({ "a.txt", other .. "/x.txt" })
    assert.is_true(await_cached(bufs))
    assert.is_true(await(bufs, nil, 5000))

    support.git({ "switch", "-q", "scoped" }, dir)
    assert.is_true(await({ bufs[1] }, merge_base(), 10000))

    assert.is_true(settle())
    vim.fn.delete(other, "rf")
    assert.is_nil(revision(bufs[2]))
  end)

  it("leaves gitsigns' own blob buffers alone", function()
    fixture("blob", { "a.txt" })
    support.git({ "switch", "-q", "main" }, dir)
    vim.fn.chdir(dir)
    local bufs = edit({ "a.txt" })
    -- diffthis reuses the source buffer's comparison text, set by its first update.
    assert.is_true(await_all(bufs, function(buf)
      local bcache = require("gitsigns.cache").cache[buf]
      return bcache and bcache.compare_text ~= nil
    end, 5000))
    require("gitsigns").diffthis()
    local blob
    assert.is_true(vim.wait(5000, function()
      blob = vim.iter(pairs(require("gitsigns.cache").cache)):find(function(buf)
        return vim.api.nvim_buf_get_name(buf):match("^gitsigns://")
      end)
      return blob ~= nil
    end, 20))
    assert.is_nil(revision(blob))

    support.git({ "switch", "-q", "blob" }, dir)
    assert.is_true(await(bufs, merge_base(), 10000))

    assert.is_true(settle())
    assert.is_nil(revision(blob))
  end)

  it("moves each buffer onto a new base once", function()
    local files = {}
    for i = 1, 18 do
      files[i] = i .. ".txt"
    end
    fixture("counted", files)
    support.git({ "switch", "-q", "main" }, dir)
    vim.fn.chdir(dir)

    local bufs = edit(vim.list_slice(files, 1, 12))
    assert.is_true(await_cached(bufs))
    assert.is_true(await(bufs, nil, 5000))

    local before = moves

    support.git({ "switch", "-q", "counted" }, dir)
    local base = merge_base()
    -- The first buffer reaching the base marks the switch; the rest attach while
    -- the moves run, onto the base already.
    assert.is_true(vim.wait(10000, function()
      return revision(bufs[1]) == base
    end, 1))
    vim.list_extend(bufs, edit(vim.list_slice(files, 13, 18)))

    assert.is_true(await(bufs, base, 10000))
    assert.is_true(settle())
    assert.equal(12, moves - before)

    -- As if every buffer had attached on the old base, then caught a burst of
    -- events before its move landed.
    for _, buf in ipairs(bufs) do
      require("gitsigns.cache").cache[buf].git_obj.revision = nil
    end
    before = moves
    for _ = 1, 3 do
      vim.api.nvim_exec_autocmds("User", { pattern = "GitSignsUpdate" })
    end

    assert.is_true(await(bufs, base, 10000))
    assert.is_true(settle())
    assert.equal(#bufs, moves - before)
  end)
end)
