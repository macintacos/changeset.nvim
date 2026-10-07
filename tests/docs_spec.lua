-- The vimdoc, not README.md: it is what :help shows, and the one that names everything.
local root = vim.fn.fnamemodify(vim.api.nvim_get_runtime_file("plugin/changeset.lua", false)[1], ":h:h")
local doc = table.concat(vim.fn.readfile(root .. "/doc/changeset.nvim.txt"), "\n")

---Whether the vimdoc defines help tag `tag`.
---@param tag string
---@return boolean
local function tagged(tag)
  return doc:find("*" .. tag .. "*", 1, true) ~= nil
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

---Loads the plugin as startup does, default keys included: a spec runs before VimEnter, which maps them.
local function load_plugin()
  vim.cmd.runtime("plugin/changeset.lua")
  vim.api.nvim_exec_autocmds("VimEnter", {})
end

---The key in each `*changeset-<key>*` tag, spelled as nvim_get_keymap() spells a lhs.
---@return table<string, true>
local function key_tags()
  local keys = {}
  for key in doc:gmatch("%*changeset%-([^*%s]+)%*") do
    keys[vim.fn.keytrans(vim.keycode(key))] = true
  end
  return keys
end

describe("doc/changeset.nvim.txt", function()
  it("tags every option", function()
    local options = leaves(require("changeset.config").get())
    assert.is_true(#options > 0)
    for _, name in ipairs(options) do
      assert.is_true(tagged("changeset-option-" .. name), name)
    end
  end)

  it("tags every sidebar key by its default", function()
    for option, lhs in pairs(require("changeset.config").get().keymaps) do
      assert.is_true(tagged("changeset-sidebar-" .. lhs), option)
    end
  end)

  it("tags every highlight group", function()
    local groups = vim.tbl_filter(function(v)
      return type(v) == "string" and v:find("^Changeset%u") ~= nil
    end, vim.tbl_values(require("changeset.render")))
    assert.is_true(#groups > 0)
    for _, name in ipairs(groups) do
      assert.is_true(tagged(name), name)
    end
  end)

  it("tags every subcommand", function()
    load_plugin()
    local subcommands = vim.fn.getcompletion("Changeset ", "cmdline")
    assert.is_true(#subcommands > 0)
    for _, sub in ipairs(subcommands) do
      local verbs = vim.fn.getcompletion("Changeset " .. sub .. " ", "cmdline")
      for _, verb in ipairs(#verbs > 0 and verbs or { "" }) do
        local name = vim.trim(sub .. " " .. verb)
        assert.is_true(tagged(":Changeset-" .. name:gsub(" ", "-")), name)
      end
    end
  end)

  it("tags every <Plug> map and every default key", function()
    load_plugin()
    local keys = key_tags()
    local plugs, defaults = 0, 0
    for _, mode in ipairs({ "n", "x" }) do
      for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
        if vim.startswith(map.lhs, "<Plug>(changeset") then
          plugs = plugs + 1
          assert.is_true(tagged(map.lhs), map.lhs)
        elseif vim.startswith(map.rhs or "", "<Plug>(changeset") then
          defaults = defaults + 1
          assert.is_true(keys[map.lhs], mode .. " " .. map.lhs)
        end
      end
    end
    assert.is_true(plugs > 0)
    assert.is_true(defaults > 0)
  end)

  it("has unique tags, one of them the options section the setup() warning names", function()
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
