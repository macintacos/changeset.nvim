local support = require("support.git")
local present = require("support.present")
require("support.gh")

---The base changeset asked gitsigns to diff each buffer against; false is the index.
---@type table<integer, string|false>
local bases = {}
---@type fun(ctx: { bufnr: integer, bcache: table })? What changeset hears each of gitsigns' reads with.
local on_read
---@type table<integer, table>
local cache = {}

-- gitsigns as changeset.review reaches it, so a read in flight is a cache entry holding no text rather than a race.
package.loaded["gitsigns.cache"] = { cache = cache }
package.loaded["gitsigns.manager"] = {
  on_update = function(fn)
    on_read = fn
  end,
}
package.loaded["gitsigns"] = {
  change_base = function(base, _, done)
    bases[vim.api.nvim_get_current_buf()] = base or false
    done()
  end,
}

require("changeset.review").activate()

describe("the gutter's base, while gitsigns reads a buffer", function()
  local dir ---@type string
  local base ---@type string
  local read ---@type integer
  local reading ---@type integer

  ---`name` in the fixture repo, cached with `text`, or with none while gitsigns reads it.
  ---@param name string
  ---@param text string[]?
  ---@return integer
  local function cached(name, text)
    local buf = vim.fn.bufadd(dir .. "/" .. name)
    vim.fn.bufload(buf)
    cache[buf] = {
      git_obj = {
        repo = {
          toplevel = dir,
          has_watcher = function()
            return false
          end,
        },
      },
      compare_text = text,
    }
    return buf
  end

  before_each(function()
    dir = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(dir, "p")
    support.feature(
      { ["a.txt"] = { "one" }, ["b.txt"] = { "one" } },
      { ["a.txt"] = { "two" }, ["b.txt"] = { "two" } },
      dir
    )
    base = support.git({ "rev-parse", "trunk" }, dir)
    read, reading = cached("a.txt", { "one" }), cached("b.txt", nil)
    vim.b[read].gitsigns_status_dict = { root = dir, head = "feature" }

    vim.api.nvim_exec_autocmds("User", { pattern = "GitSignsUpdate", data = { buffer = read }, modeline = false })

    assert.is_true(vim.wait(5000, function()
      return bases[read] ~= nil
    end, 20))
  end)

  after_each(function()
    for buf in pairs(cache) do
      cache[buf] = nil
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    vim.fn.delete(dir, "rf")
  end)

  it("leaves a buffer it is still reading where it is, as the base lands on the rest", function()
    assert.are.same(base, bases[read])
    assert.is_nil(bases[reading])
  end)

  it("moves a buffer onto the base once gitsigns publishes its read", function()
    cache[reading].compare_text = { "one" }

    present(on_read)({ bufnr = reading, bcache = cache[reading] })

    assert.are.same(base, bases[reading])
  end)
end)
