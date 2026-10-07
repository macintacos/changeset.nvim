-- The vimdoc, not README.md: it is what :help shows, and CI fails when it lags the README.
local root = vim.fn.fnamemodify(vim.api.nvim_get_runtime_file("plugin/changeset.lua", false)[1], ":h:h")
-- panvimdoc re-wraps at 78 columns, inside inline code too.
local flat = table.concat(vim.fn.readfile(root .. "/doc/changeset.nvim.txt"), "\n"):gsub("%s+", " ")

---Whether `name` appears whole: not as the prefix of a longer sibling (`keymaps.next` of `keymaps.next_section`).
---@param name string
---@return boolean
local function mentions(name)
  return flat:find("%f[%w_.]" .. vim.pesc(name) .. "%f[^%w_]") ~= nil
end

---Every leaf of `tbl` as a dotted path; a list is one leaf, since a list-valued option is documented by its name.
---@param tbl table
---@param prefix string?
---@param out string[]?
---@return string[]
local function leaves(tbl, prefix, out)
  out = out or {}
  for key, value in pairs(tbl) do
    local path = prefix and prefix .. "." .. key or key
    if type(value) == "table" and not vim.islist(value) then
      leaves(value, path, out)
    else
      out[#out + 1] = path
    end
  end
  return out
end

describe("doc/changeset.nvim.txt", function()
  it("documents every option", function()
    local options = leaves(require("changeset.config").get())
    assert.is_true(#options > 0)
    for _, name in ipairs(options) do
      assert.is_true(mentions(name), name)
    end
  end)

  it("documents every highlight group", function()
    local groups = vim.tbl_filter(function(v)
      return type(v) == "string" and v:find("^Changeset%u") ~= nil
    end, vim.tbl_values(require("changeset.render")))
    assert.is_true(#groups > 0)
    for _, name in ipairs(groups) do
      assert.is_true(mentions(name), name)
    end
  end)

  it("documents every subcommand and <Plug> map", function()
    vim.cmd.runtime("plugin/changeset.lua")
    local subcommands = vim.fn.getcompletion("Changeset ", "cmdline")
    local plugs = vim.tbl_filter(
      function(lhs)
        return vim.startswith(lhs, "<Plug>(changeset")
      end,
      vim.tbl_map(function(map)
        return map.lhs
      end, vim.api.nvim_get_keymap("n"))
    )
    assert.is_true(#subcommands > 0)
    assert.is_true(#plugs > 0)
    for _, sub in ipairs(subcommands) do
      local verbs = vim.fn.getcompletion("Changeset " .. sub .. " ", "cmdline")
      for _, verb in ipairs(#verbs > 0 and verbs or { "" }) do
        local name = vim.trim(sub .. " " .. verb)
        assert.truthy(flat:find(":Changeset " .. name, 1, true), name)
      end
    end
    for _, lhs in ipairs(plugs) do
      assert.truthy(flat:find(lhs, 1, true), lhs)
    end
  end)

  it("has unique tags, one of them for the options section", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile(vim.fn.readfile(root .. "/doc/changeset.nvim.txt"), dir .. "/changeset.nvim.txt")
    local ok, err = pcall(vim.cmd.helptags, dir)
    local tags = ok and "\n" .. table.concat(vim.fn.readfile(dir .. "/tags"), "\n") or ""
    vim.fn.delete(dir, "rf")
    assert.is_true(ok, err)
    assert.truthy(tags:find("\nchangeset%.nvim%-options\t"))
  end)
end)
