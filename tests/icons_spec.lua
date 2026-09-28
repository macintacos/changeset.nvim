local deps = require("support.deps")

local PATH = "lua/changeset/init.lua"
local BLANK = { " ", "Normal" }

---A resolver that has not picked its provider yet.
local function fresh()
  package.loaded["changeset.icons"] = nil
  return require("changeset.icons")
end

-- Cases run in order and only ever add a provider: a loaded plugin cannot be unloaded.
describe("changeset.icons", function()
  it("draws a blank glyph in Normal with neither provider", function()
    local icons = fresh()
    assert.are.same(BLANK, { icons.get("file", PATH) })
    assert.are.same(BLANK, { icons.get("directory", "src") })
    assert.are.same(BLANK, { icons.get("lsp", "Function") })
  end)

  it("keeps the provider it picked on first use", function()
    local icons = fresh()
    icons.get("file", PATH)
    vim.opt.rtp:prepend(deps.path("nvim-web-devicons"))
    assert.are.same(BLANK, { icons.get("file", PATH) })
  end)

  it("takes file icons from nvim-web-devicons without mini.icons", function()
    local icons = fresh()
    local glyph, hl = icons.get("file", PATH)
    assert.are.equal("DevIconLua", hl)
    assert.are.equal((require("nvim-web-devicons").get_icon("init.lua")), glyph)
    assert.are.same(BLANK, { icons.get("directory", "src") })
    assert.are.same(BLANK, { icons.get("lsp", "Function") })
  end)

  it("prefers mini.icons over nvim-web-devicons once it is set up", function()
    vim.opt.rtp:prepend(deps.path("mini.icons"))
    require("mini.icons").setup()
    local icons = fresh()
    for _, case in ipairs({ { "file", PATH }, { "directory", "src" }, { "lsp", "Function" } }) do
      local glyph, hl = MiniIcons.get(case[1], case[2])
      assert.are.same({ glyph, hl }, { icons.get(case[1], case[2]) })
    end
  end)
end)
