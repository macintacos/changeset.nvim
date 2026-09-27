---What the PR Review Mode specs share: gitsigns with this config's plugin file
---sourced over it, a fake gh, and waits on the base each buffer diffs against.
---Requiring it is what loads them; each spec runs in its own nvim.
local support = require("support.git")

vim.opt.rtp:prepend(require("support.deps").path("gitsigns.nvim"))

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

vim.o.hidden = true

local M = {}

---Base changes started so far, across every buffer.
---@type integer
M.moves = 0

local in_flight = 0
local Obj = require("gitsigns.git").Obj
local change_revision = Obj.change_revision
Obj.change_revision = function(...)
  in_flight, M.moves = in_flight + 1, M.moves + 1
  local result = change_revision(...)
  in_flight = in_flight - 1
  return result
end

---@param buf integer
---@return string? revision nil both before gitsigns caches the buffer and on the
---index, so await the cache before awaiting nil.
function M.revision(buf)
  local bcache = require("gitsigns.cache").cache[buf]
  return bcache and bcache.git_obj.revision
end

---@param bufs integer[]
---@param pred fun(buf: integer): boolean
---@param timeout integer
---@return boolean
function M.await_all(bufs, pred, timeout)
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
function M.await(bufs, want, timeout)
  return M.await_all(bufs, function(buf)
    return M.revision(buf) == want
  end, timeout)
end

---@param bufs integer[]
---@return boolean
function M.await_cached(bufs)
  return M.await_all(bufs, function(buf)
    return require("gitsigns.cache").cache[buf] ~= nil
  end, 5000)
end

---Wait until no base change has been in flight for 200 ms.
---@return boolean
function M.settle()
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
function M.edit(files)
  local bufs = {}
  for _, name in ipairs(files) do
    vim.cmd.edit(name)
    bufs[#bufs + 1] = vim.api.nvim_get_current_buf()
  end
  return bufs
end

---A repo on `main` with no commits, in a directory of its own.
---@return string dir
function M.repo()
  local dir = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  support.init_repo("main", dir)
  return dir
end

---`dir`'s repo with `files` committed on `main`, and `branch` carrying a change to each.
---@param dir string
---@param branch string
---@param files string[]
function M.fixture(dir, branch, files)
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

---@param dir string
---@param branch string?
---@return string
function M.merge_base(dir, branch)
  return support.git({ "merge-base", "HEAD", branch or "main" }, dir)
end

---Let a case's base changes land, then drop its buffers, its base and its repo.
---@param dir string The case's repo.
---@param cwd string Where the case started.
function M.teardown(dir, cwd)
  -- Let every base change in flight land before its repo is deleted under it.
  assert(M.settle(), "a base change never landed")
  vim.cmd("silent! %bwipeout!")
  -- The next fixture is another repo, where this one's merge base does not exist
  -- and every attach against it would fail.
  require("gitsigns").reset_base(true)
  vim.fn.chdir(cwd)
  vim.fn.delete(dir, "rf")
end

return M
