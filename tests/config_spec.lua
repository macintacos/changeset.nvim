local Notify = require("support.notify")

describe("changeset.config", function()
  local config = require("changeset.config")

  after_each(function()
    config.setup()
  end)

  it("lays each setup() over the defaults, not over the last one", function()
    config.setup({ keymaps = { jump = "o" } })
    config.setup({ layout = { min_file_width = 100 } })
    assert.equal("<CR>", config.get().keymaps.jump)
    assert.equal(100, config.get().layout.min_file_width)
  end)

  it("replaces the review comment save keys rather than merging them", function()
    assert.same({ "<C-CR>", "<C-s>" }, config.get().review_comment.save)
    config.setup({ review_comment = { save = { "<C-j>" } } })
    assert.same({ "<C-j>" }, config.get().review_comment.save)
  end)

  it("puts the review comment bubble in the sign column by default", function()
    assert.is_true(config.get().review_comment.sign)
  end)

  it("frames the review with nothing by default, each end set on its own", function()
    assert.same({ header = "", footer = "" }, config.get().review)
    config.setup({ review = { header = "x" } })
    assert.same({ header = "x", footer = "" }, config.get().review)
  end)

  it("rejects a bad value, naming the option, and keeps the options in force", function()
    config.setup({ layout = { min_file_width = 100 } })
    for _, case in ipairs({
      { { keymaps = { jump = true } }, "keymaps.jump" },
      { { keymaps = { jump = "" } }, "keymaps.jump" },
      { { layout = { min_file_width = "80" } }, "layout.min_file_width" },
      { { keymaps = false }, "keymaps" },
      { { review_comment = false }, "review_comment" },
      { { review_comment = { save = "<C-s>" } }, "review_comment.save" },
      { { review_comment = { save = {} } }, "review_comment.save" },
      { { review_comment = { save = { "" } } }, "review_comment.save" },
      { { review_comment = { sign = "no" } }, "review_comment.sign" },
      { { review_comment = { blocks = "yes" } }, "review_comment.blocks" },
      { { review = false }, "review" },
      { { review = { header = 1 } }, "review.header" },
      { { review = { footer = true } }, "review.footer" },
      { { unified_diff = false }, "unified_diff" },
      { { unified_diff = { keep = "some" } }, "unified_diff.keep" },
      { { unified_diff = { keep = false } }, "unified_diff.keep" },
    }) do
      local ok, err = pcall(config.setup, case[1])
      assert.is_false(ok)
      assert.is_string(err)
      assert.truthy(string.find(tostring(err), case[2], 1, true), err)
    end
    assert.equal(100, config.get().layout.min_file_width)
  end)

  describe("unknown options", function()
    local notes, restore

    ---Stand in for a notifier, such as mini.notify, that replaces `vim.notify` once it is set up.
    local function set_up_notifier()
      notes, restore = Notify.capture()
    end

    before_each(function()
      notes, restore = {}, nil
    end)

    after_each(function()
      -- Lets a warning still scheduled land here, not in the next test.
      vim.wait(20)
      if restore then
        restore()
      end
    end)

    it(
      "warns once through a notifier set up later in startup, naming each option it doesn't know whatever its value, and applies the rest",
      function()
        config.setup({ keymaps = { next = "]h", prev = { "[h" }, jump = "o" } })
        set_up_notifier()

        assert.equal("o", config.get().keymaps.jump)
        vim.wait(1000, function()
          return #notes > 0
        end)
        vim.wait(20)
        assert.equal(1, #notes)
        assert.equal(vim.log.levels.WARN, notes[1].level)
        assert.truthy(notes[1].msg:find("keymaps.next, keymaps.prev", 1, true), notes[1].msg)
      end
    )

    it("warns that a leftover pr_review option is unknown, and applies the rest", function()
      config.setup({ pr_review = { enabled = true }, keymaps = { jump = "o" } })
      set_up_notifier()

      assert.equal("o", config.get().keymaps.jump)
      vim.wait(1000, function()
        return #notes > 0
      end)
      vim.wait(20)
      assert.equal(1, #notes)
      assert.equal(vim.log.levels.WARN, notes[1].level)
      assert.truthy(notes[1].msg:find("pr_review", 1, true), notes[1].msg)
    end)

    it("forgets the unknown options of an earlier setup()", function()
      config.setup({ keymaps = { next = "]h" } })

      config.setup({ keymaps = { jump = "o" } })

      assert.same({}, config.unknown())
    end)

    it("says nothing when it knows every option", function()
      set_up_notifier()
      config.setup({ keymaps = { jump = "o" }, review_comment = { save = { "<C-j>" } } })
      vim.wait(20)

      assert.same({}, notes)
    end)
  end)

  describe("_split", function()
    it("names each option it doesn't know by its dotted path, keeping the rest", function()
      local known, unknown = config._split({ keymaps = { next = "]h", jump = "o" }, colour = "red" })

      assert.same({ keymaps = { jump = "o" } }, known)
      assert.same({ "colour", "keymaps.next" }, unknown)
    end)

    it("takes a list-valued option as one option", function()
      local known, unknown = config._split({ review_comment = { save = { "<C-j>" } } })

      assert.same({ review_comment = { save = { "<C-j>" } } }, known)
      assert.same({}, unknown)
    end)
  end)
end)
