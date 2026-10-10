local Fixture = require("support.git")
local base_preview = require("changeset.base_preview")
local present = require("support.present")
local render = require("changeset.render")

---Each line of `buf` as it reads on screen, right-aligned text included, glyphs dropped and runs of spaces squeezed.
---@param buf integer
---@return string[]
local function screen(buf)
  local out = {}
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local right = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, { i - 1, 0 }, { i - 1, -1 }, { details = true })) do
      for _, chunk in ipairs(present(mark[4]).virt_text or {}) do
        right[#right + 1] = chunk[1]
      end
    end
    local text = (line .. " " .. table.concat(right)):gsub("[\128-\255]+", ""):gsub("%s+", " ")
    out[i] = vim.trim(text)
  end
  return out
end

describe("changeset.base_preview", function()
  local root ---@type string
  local buf ---@type integer
  local win ---@type integer

  -- `trunk` holding `mod.lua`, then `feature` changing it and adding `new.lua` in one commit, checked out.
  before_each(function()
    root = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(root, "p")
    Fixture.feature(
      { ["mod.lua"] = { "return 1" } },
      { ["mod.lua"] = { "return 2" }, ["new.lua"] = { "x", "y" } },
      root
    )
    buf = vim.api.nvim_create_buf(false, true)
    win = vim.api.nvim_open_win(buf, false, { relative = "editor", row = 0, col = 0, width = 60, height = 10 })
    vim.v.errmsg = ""
  end)

  after_each(function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    vim.fn.delete(root, "rf")
  end)

  ---Show `ref` in the preview and wait for the diff to land.
  ---@param ref string
  ---@return string[]
  local function shown(ref)
    base_preview.show(buf, root, ref, "branch")
    assert.is_true(vim.wait(5000, function()
      return not vim.iter(screen(buf)):any(function(line)
        return line:find("reading", 1, true) ~= nil
      end)
    end, 10))
    return screen(buf)
  end

  it("draws the sidebar's header for the ref, then the commits and files HEAD has against it", function()
    local change = Fixture.git({ "rev-parse", "--short", "HEAD" }, root)

    assert.same(
      { "trunk", "2 files 1 commit +3 -1", "", change .. " change", "", "mod.lua +1 -1", "new.lua +2 -0" },
      shown("trunk")
    )
  end)

  it("lists the five newest commits, then counts the rest, so the files stay in view", function()
    for i = 1, 6 do
      Fixture.git({ "commit", "-q", "--allow-empty", "-m", "c" .. i }, root)
    end

    local lines = shown("trunk")

    assert.same({ "c6", "c5", "c4", "c3", "c2", "2 more" }, {
      present(present(lines[4]):match("%S+$")),
      present(present(lines[5]):match("%S+$")),
      present(present(lines[6]):match("%S+$")),
      present(present(lines[7]):match("%S+$")),
      present(present(lines[8]):match("%S+$")),
      lines[9],
    })
    assert.equal("mod.lua +1 -1", lines[11])
  end)

  it("names the ref at once, while the diff is still being read", function()
    base_preview.show(buf, root, "trunk", "branch")

    assert.equal("trunk", screen(buf)[1])
  end)

  it("leads the header with the glyph of the ref's kind", function()
    local sha = Fixture.git({ "rev-parse", "--short", "trunk" }, root)

    base_preview.show(buf, root, sha, "commit")

    local first = present(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    assert.truthy(vim.startswith(vim.trim(first), render.REF_ICONS.commit), first)
  end)

  -- A picker waiting on a key repaints nothing itself.
  it("repaints once the diff lands", function()
    local painted
    -- rawset: `vim.cmd` makes each command's function on first use, so clearing the field brings the real one back.
    rawset(vim.cmd, "redraw", function()
      painted = screen(buf)
    end)

    local lines = shown("trunk")
    rawset(vim.cmd, "redraw", nil)

    assert.same(lines, painted)
  end)

  it("says when HEAD shares no history with the ref", function()
    local lines = shown("nowhere")

    assert.equal("nowhere", lines[1])
    assert.truthy(present(lines[3]):find("no history", 1, true), lines[3])
  end)

  it("leaves a preview the picker has moved past alone", function()
    base_preview.show(buf, root, "trunk", "branch")
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })

    vim.wait(500)

    assert.equal("", vim.v.errmsg)
  end)
end)
