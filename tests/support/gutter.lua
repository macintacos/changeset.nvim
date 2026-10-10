---What the gutter-base specs share: gitsigns with `plugin/changeset.lua` loaded over it, so the
---base is applied from the session's first update as it is at startup, a fake gh, and waits on the
---base each buffer diffs against. Requiring it is what loads them; each spec runs in its own nvim.
local support = require("support.git")

-- Plenary starts each spec's nvim with `--noplugin`, so the startup path is loaded here.
vim.cmd.runtime("plugin/changeset.lua")
vim.opt.rtp:prepend(require("support.deps").path("gitsigns.nvim"))

-- `changeset.review` state outlives each case; a fresh `gutter.repo()` per case isolates
-- it and `fork_point`'s cache, since both are keyed by repository.
require("gitsigns").setup()

require("support.gh")

vim.o.hidden = true

local M = {}

---Base changes started so far, across every buffer.
---@type integer
M.moves = 0

---Base changes started so far toward each revision.
---@type table<string, integer>
M.moves_to = {}

local in_flight = 0
local Obj = require("gitsigns.git").Obj
local change_revision = Obj.change_revision
Obj.change_revision = function(self, revision)
  in_flight, M.moves = in_flight + 1, M.moves + 1
  if revision then
    M.moves_to[revision] = (M.moves_to[revision] or 0) + 1
  end
  local result = change_revision(self, revision)
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

local advanced = 0

---Commit one more file on the checked-out branch, so its tip moves past any fork point cut before it.
---@param dir string
function M.advance(dir)
  advanced = advanced + 1
  vim.fn.writefile({ "ahead " .. advanced }, dir .. "/ahead" .. advanced .. ".txt")
  support.commit("advance " .. advanced, dir)
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
  vim.fn.chdir(cwd)
  vim.fn.delete(dir, "rf")
end

return M
