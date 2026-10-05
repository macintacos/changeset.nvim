local confirm = require("changeset.confirm")

describe("changeset.confirm", function()
  local select, asked

  before_each(function()
    select, asked = vim.ui.select, {}
  end)

  after_each(function()
    vim.ui.select = select
  end)

  ---Answers every question with what `choose` picks from its items, or dismisses it when that is nil.
  ---@param choose fun(items: string[]): string?
  local function answer(choose)
    vim.ui.select = function(items, opts, on_choice)
      table.insert(asked, opts.prompt)
      local item = choose(items)
      on_choice(item, item and vim.fn.index(items, item) + 1 or nil)
    end
  end

  ---@return boolean confirmed
  local function ask()
    local confirmed = false
    confirm.ask("Abandon the pending review on #412?", function()
      confirmed = true
    end)
    return confirmed
  end

  it("asks the question", function()
    answer(function() end)

    ask()

    assert.truthy(asked[1]:find("Abandon the pending review on #412?", 1, true))
  end)

  it("confirms when yes is chosen", function()
    answer(function(items)
      return vim.iter(items):find(function(item)
        return item:match("^Yes")
      end)
    end)

    assert.is_true(ask())
  end)

  it("declines when dismissed", function()
    answer(function() end)

    assert.is_false(ask())
  end)

  it("declines on the first choice, where a picker's stray <CR> lands", function()
    answer(function(items)
      return items[1]
    end)

    assert.is_false(ask())
  end)
end)
