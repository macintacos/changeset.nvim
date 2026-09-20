local buffers = require("plugins.prtree.buffers")

describe("prtree.buffers", function()
  local tmp

  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
  end)

  after_each(function()
    vim.fn.delete(tmp, "rf")
  end)

  describe("load", function()
    it("loads a file's contents without listing its buffer", function()
      local path = tmp .. "/a.lua"
      vim.fn.writefile({ "local x = 1", "return x" }, path)

      local buf = buffers.load(path)

      assert.is_not_nil(buf)
      assert.is_true(vim.api.nvim_buf_is_loaded(buf))
      assert.is_false(vim.bo[buf].buflisted)
      assert.same({ "local x = 1", "return x" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end)

    it("reports nothing for a path that is not a readable file", function()
      assert.is_nil(buffers.load(tmp .. "/missing.lua"))
      assert.is_nil(buffers.load(tmp))
    end)
  end)
end)
