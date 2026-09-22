local window = require("plugins.changeset.window")
local Fixture = require("support.git")

---@type changeset.Band
local BAND = { icon = "󰢱", icon_hl = "MiniIconsAzure", path = "src/session.ts" }

local data = vim.fn.stdpath("data") .. "/site/pack/"
vim.opt.rtp:prepend(vim.fn.glob(data .. "*/opt/gitsigns.nvim", false, true)[1])
require("gitsigns").setup()

describe("changeset.window gitsigns", function()
  local dir, path

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
    return vim.wait(5000, function()
      return require("gitsigns.cache").cache[buf] ~= nil
    end, 20)
  end

  it("attaches gitsigns to a file previewed from an autocommand", function()
    window.open(vim.api.nvim_create_buf(false, true))

    preview_from_autocmd()

    assert.is_true(attached(vim.fn.bufnr(path)))
  end)
end)
