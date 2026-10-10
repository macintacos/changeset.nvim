local deps = require("support.deps")
local present = require("support.present")

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
    assert.is_nil(icons.source())
  end)

  it("keeps the provider it picked on first use", function()
    local icons = fresh()
    icons.get("file", PATH)
    vim.opt.rtp:prepend(deps.path("nvim-web-devicons"))
    assert.are.same(BLANK, { icons.get("file", PATH) })
    assert.equal("nvim-web-devicons", icons.source())
  end)

  it("takes file icons from nvim-web-devicons without mini.icons", function()
    vim.opt.rtp:prepend(deps.path("nvim-web-devicons"))
    local icons = fresh()
    local glyph, hl = icons.get("file", PATH)
    assert.are.equal("DevIconLua", hl)
    assert.are.equal((require("nvim-web-devicons").get_icon("init.lua")), glyph)
    assert.are.equal("DevIconMakefile", select(2, icons.get("file", "src/Makefile")))
    assert.are.same(BLANK, { icons.get("directory", "src") })
    assert.are.same(BLANK, { icons.get("lsp", "Function") })
    assert.equal("nvim-web-devicons", icons.source())
  end)

  it("draws a provider's glyph in Normal when it gives no highlight", function()
    -- The provider reads mini.icons as a global, so the spec swaps that global itself.
    -- selene: allow(global_usage)
    rawset(_G, "MiniIcons", {
      get = function()
        return "x"
      end,
    })
    assert.are.same({ "x", "Normal" }, { fresh().get("file", PATH) })
    -- The provider reads mini.icons as a global, so the spec swaps that global itself.
    -- selene: allow(global_usage)
    rawset(_G, "MiniIcons", nil)
  end)

  it("prefers mini.icons over nvim-web-devicons once it is set up", function()
    vim.opt.rtp:prepend(deps.path("mini.icons"))
    require("mini.icons").setup()
    local icons = fresh()
    for _, case in ipairs({ { "file", PATH }, { "directory", "src" }, { "lsp", "Function" } }) do
      local glyph, hl = present(MiniIcons).get(case[1], case[2])
      assert.are.same({ glyph, hl }, { icons.get(case[1], case[2]) })
    end
    assert.equal("mini.icons", icons.source())
  end)

  it("sees a mini.icons that the devicons probe sets up", function()
    -- The provider reads mini.icons as a global, so the spec swaps that global itself.
    -- selene: allow(global_usage)
    rawset(_G, "MiniIcons", nil)
    package.loaded["nvim-web-devicons"] = nil
    package.preload["nvim-web-devicons"] = function()
      require("mini.icons").setup()
      present(MiniIcons).mock_nvim_web_devicons()
      return package.loaded["nvim-web-devicons"]
    end
    local got = { fresh().get("directory", "src") }
    local glyph, hl = present(MiniIcons).get("directory", "src")
    assert.are.same({ glyph, hl }, got)
  end)
end)
