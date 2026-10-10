local buffers = require("changeset.buffers")
local window = require("changeset.window")
local Fixture = require("support.git")
local present = require("support.present")

---@type changeset.Band
local BAND = { icon = "󰢱", icon_hl = "MiniIconsAzure", path = "src/session.ts" }

vim.opt.rtp:prepend(require("support.deps").path("gitsigns.nvim"))
require("gitsigns").setup()

describe("changeset.window gitsigns", function()
  local dir ---@type string
  local path ---@type string

  before_each(function()
    vim.cmd("only")
    dir = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(dir, "p")
    Fixture.init_repo("main", dir)
    path = dir .. "/a.txt"
    vim.fn.writefile({ "one" }, path)
    Fixture.commit("add a", dir)
    vim.fn.writefile({ "one", "two" }, path)
  end)

  after_each(function()
    window.close()
    vim.cmd("only")
    vim.cmd("silent! bwipeout! " .. vim.fn.bufnr(path))
    vim.fn.delete(dir, "rf")
  end)

  ---Preview `path` the way the sidebar does: from inside an autocommand.
  local function preview_from_autocmd()
    vim.api.nvim_create_autocmd("User", {
      pattern = "ChangesetWindowSpec",
      once = true,
      callback = function()
        window.preview(path, 1, BAND)
      end,
    })
    vim.api.nvim_exec_autocmds("User", { pattern = "ChangesetWindowSpec" })
  end

  ---@param buf integer
  ---@return boolean
  local function attached(buf)
    return (vim.wait(5000, function()
      return require("gitsigns.cache").cache[buf] ~= nil
    end, 20))
  end

  ---Whether gitsigns attached to `buf` off screen and put its signs off until the buffer is seen.
  ---@param buf integer
  ---@return boolean
  local function deferred(buf)
    return (
      vim.wait(5000, function()
        local bcache = require("gitsigns.cache").cache[buf]
        return bcache ~= nil and bcache.update_on_view == true
      end, 20)
    )
  end

  ---@param buf integer
  ---@return boolean
  local function signed(buf)
    return (vim.wait(5000, function()
      return #(require("gitsigns").get_hunks(buf) or {}) > 0
    end, 20))
  end

  it("attaches gitsigns to a file previewed from an autocommand", function()
    window.open(vim.api.nvim_create_buf(false, true))

    preview_from_autocmd()

    assert.is_true(attached(vim.fn.bufnr(path)))
  end)

  it("shows signs for a file gitsigns attached to while it was off screen", function()
    -- As the symbol walk loads a changed file: outside an autocommand, so `BufRead` attaches it.
    local buf = present(buffers.load(path))
    assert.is_true(deferred(buf))
    window.open(vim.api.nvim_create_buf(false, true))

    preview_from_autocmd()

    assert.is_true(signed(buf))
  end)

  it("draws its bar over the covers the unified diff lays over gitsigns' signs", function()
    window.open(vim.api.nvim_create_buf(false, true))
    window.focus()
    local spanned =
      vim.tbl_extend("force", BAND, { span = { first = 1, last = 2, icon = "󰊕", icon_hl = "MiniIconsBlue" } }) --[[@as changeset.Band]]

    window.preview(path, 1, spanned)
    vim.cmd("redraw")

    local target = present(vim.fn.win_findbuf(vim.fn.bufnr(path))[1])
    local marks = vim.api.nvim_buf_get_extmarks(
      vim.fn.bufnr(path),
      require("changeset.preview_bar")._namespace(target),
      0,
      -1,
      { details = true }
    )
    local covers = require("gitsigns.config").config.sign_priority + 1
    assert.is_true(#marks > 0)
    for _, mark in ipairs(marks) do
      assert.is_true(present(mark[4]).priority > covers)
    end
  end)
end)
