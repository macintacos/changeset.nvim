local help = require("plugins.changetree.help")

describe("changetree.help", function()
  it("pads the keys into a column, ordered by key", function()
    local lines = help._lines({
      { lhs = "q", desc = "Close the tree" },
      { lhs = "<C-V>", desc = "Go to this change in a vertical split" },
    })

    assert.same({
      "<C-V>  Go to this change in a vertical split",
      "q      Close the tree",
    }, lines)
  end)

  it("lists only the mappings that describe themselves", function()
    local lines = help._lines({
      { lhs = "q", desc = "Close the tree" },
      { lhs = "<Plug>NetrwBrowseX", rhs = ":call netrw#BrowseX()<CR>" },
    })

    assert.same({ "q  Close the tree" }, lines)
  end)
end)
