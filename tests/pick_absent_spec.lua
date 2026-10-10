require("support.gh")
local Fixture = require("support.git")
local Notify = require("support.notify")
local Sidebar = require("support.sidebar")
local changeset = require("changeset")
local pick = require("changeset.pick")
local window = require("changeset.window")

---Replace `vim.ui.select` with a recorder until `restore` is called. It answers nothing: a spec answers by calling
---`on_choice` itself, when it likes.
---@return table[] calls Each call's `items`, `opts` and `on_choice`.
---@return fun() restore
local function record_select()
  local real, calls = vim.ui.select, {}
  vim.ui.select = function(items, opts, on_choice)
    calls[#calls + 1] = { items = items, opts = opts, on_choice = on_choice }
  end
  return calls, function()
    vim.ui.select = real
  end
end

---@param buf integer
---@return string
local function name_of(buf)
  return vim.api.nvim_buf_get_name(buf)
end

describe("changeset.pick without mini.pick", function()
  assert(not pcall(require, "mini.pick") and MiniPick == nil, "mini.pick must be neither installed nor set up")

  local tmp, previous_dir, file_win, notes, restore_notify, calls, restore_select

  before_each(function()
    tmp, previous_dir = Fixture.enter_tempdir()
    Fixture.feature_numbered(tmp)
    vim.cmd.edit("plain.lua")
    file_win = vim.api.nvim_get_current_win()
    notes, restore_notify = Notify.capture()
    calls, restore_select = record_select()
    -- The picker lists the symbols the sidebar has read, so let it read them first.
    changeset.open()
    Sidebar.settle()
    vim.api.nvim_set_current_win(file_win)
  end)

  after_each(function()
    restore_select()
    restore_notify()
    changeset.close()
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
  end)

  it("offers the changes through vim.ui.select, under the picker's title", function()
    pick.pick()

    assert.equal(1, #calls)
    assert.equal("Changeset (vs trunk)", calls[1].opts.prompt)
    assert.same(
      {
        "mod.lua › Other changes › L2 changed 2",
        "mod.lua › Other changes › L8 changed 8",
        "other.lua › Other changes › L3 return 2",
      },
      vim.tbl_map(function(item)
        return item.text
      end, calls[1].items)
    )
  end)

  it("shows each change as its trail and name", function()
    pick.pick()

    assert.equal("mod.lua › Other changes › L8 changed 8", calls[1].opts.format_item(calls[1].items[2]))
  end)

  it("opens the chosen file at its line", function()
    pick.pick()

    calls[1].on_choice(calls[1].items[2], 2)

    assert.truthy(vim.endswith(name_of(0), "mod.lua"))
    assert.equal(8, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("opens nothing when the choice is cancelled", function()
    pick.pick()

    calls[1].on_choice(nil, nil)

    assert.truthy(vim.endswith(name_of(0), "plain.lua"))
  end)

  it("returns nil at once and opens the choice once vim.ui.select answers, which may be later", function()
    local chosen = pick.pick()

    assert.is_nil(chosen)
    assert.truthy(vim.endswith(name_of(0), "plain.lua"))
    calls[1].on_choice(calls[1].items[1], 1)
    assert.truthy(vim.endswith(name_of(0), "mod.lua"))
  end)

  it("opens the chosen file in the window the sidebar was opened from, not in the sidebar", function()
    -- A second window left of the file's, so that the file's is not the first one in the tab.
    vim.cmd("leftabove vnew")
    vim.api.nvim_set_current_win(file_win)
    local sidebar = assert(window.win())
    vim.api.nvim_set_current_win(sidebar)

    pick.pick()
    calls[1].on_choice(calls[1].items[1], 1)

    assert.equal(file_win, vim.api.nvim_get_current_win())
    assert.truthy(vim.endswith(name_of(0), "mod.lua"))
    assert.equal(sidebar, window.win())
    assert.equal(window.buf(), vim.api.nvim_win_get_buf(sidebar))
  end)

  it("warns about the changeset, not about mini.pick, when there is none", function()
    changeset.close()
    Fixture.git({ "checkout", "-q", "--orphan", "unrelated" }, tmp)
    Fixture.commit("unrelated", tmp)

    pick.pick()

    assert.equal(0, #calls)
    assert.equal(1, #notes)
    assert.equal(vim.log.levels.WARN, notes[1].level)
    assert.truthy(notes[1].msg:find("no merge base", 1, true))
  end)

  describe("installed but not set up", function()
    local rtp

    before_each(function()
      rtp = vim.o.runtimepath
      vim.opt.runtimepath:prepend(require("support.deps").path("mini.pick"))
      assert(pcall(require, "mini.pick") and MiniPick == nil, "mini.pick must be installed but not set up")
    end)

    after_each(function()
      vim.o.runtimepath = rtp
      package.loaded["mini.pick"] = nil
    end)

    it("falls back to vim.ui.select as well", function()
      pick.pick()

      assert.equal(1, #calls)
      assert.equal("Changeset (vs trunk)", calls[1].opts.prompt)
    end)
  end)
end)
