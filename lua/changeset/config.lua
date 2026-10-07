---The user's options: the defaults, and what `setup()` made of them. Read when a module
---acts, never when it loads, so a later `setup()` reaches it.
local M = {}

---@class changeset.Config
---@field keymaps? changeset.Config.Keymaps The sidebar's keys, and the step keys it binds globally while open; each a key or `false` to leave it unbound.
---@field layout? changeset.Config.Layout
---@field pr_review? changeset.Config.PrReview
---@field review_comment? changeset.Config.ReviewComment

---@class changeset.Config.Keymaps
---@field jump? string|false Go to this change. Default `<CR>`.
---@field jump_close? string|false Go to this change and close the tree. Default `<S-CR>`.
---@field jump_vsplit? string|false Go to this change in a vertical split. Default `/`.
---@field jump_split? string|false Go to this change in a split. Default `-`.
---@field jump_tab? string|false Go to this change in a new tab. Default `<C-t>`.
---@field close? string|false Close the tree. Default `q`.
---@field expand? string|false Expand. Default `l`.
---@field collapse? string|false Collapse, or step out to the parent. Default `h`.
---@field collapse_all? string|false Collapse every file. Default `H`.
---@field expand_all? string|false Expand every file. Default `L`.
---@field next_section? string|false Next section. Default `]]`.
---@field prev_section? string|false Previous section. Default `[[`.
---@field refresh? string|false Rebuild the tree. Default `R`.
---@field yank? string|false Yank path:line. Default `y`.
---@field delete_comment? string|false Delete the review comment a Comments row lists. Default `d`.
---@field help? string|false Show these keymaps. Default `?`.
---@field filter_kinds? string|false Filter by symbol kind. Default `F`.
---@field filter? string|false Filter the tree. Default `f`.
---@field next? string|false Next change, from any window while the sidebar is open. Default off.
---@field prev? string|false Previous change, from any window while the sidebar is open. Default off.

---@class changeset.Config.Layout
---@field min_file_width? number Narrower than this beside the sidebar, the files get the width and the tree moves below them. Default 80.

---@class changeset.Config.PrReview
---@field enabled? boolean Turn PR Review Mode on for every branch but the default. Only a restart turns it off again. Default false.

---@class changeset.Config.ReviewComment
---@field save? string[] Keys that save a review comment and close its window, in insert and normal mode. Default { "<C-CR>", "<C-s>" }.
---@field sign? boolean Put a comment bubble in the sign column on each review comment's first line; `false` leaves it to a statuscolumn that draws `require("changeset").bubble()`. Default true.
---@field blocks? boolean Start the session showing each review comment's whole text in a box under its last line, rather than its first line at the end of the line; `:Changeset comment toggle` switches. Default false.

---The options in force: every top-level field set.
---@class changeset.Options : changeset.Config
---@field keymaps changeset.Config.Keymaps
---@field layout changeset.Config.Layout
---@field pr_review changeset.Config.PrReview
---@field review_comment changeset.Config.ReviewComment

---@type changeset.Options
local DEFAULTS = {
  keymaps = {
    jump = "<CR>",
    jump_close = "<S-CR>",
    jump_vsplit = "/",
    jump_split = "-",
    jump_tab = "<C-t>",
    close = "q",
    expand = "l",
    collapse = "h",
    collapse_all = "H",
    expand_all = "L",
    next_section = "]]",
    prev_section = "[[",
    refresh = "R",
    yank = "y",
    delete_comment = "d",
    help = "?",
    filter_kinds = "F",
    filter = "f",
    next = false,
    prev = false,
  },
  layout = { min_file_width = 80 },
  pr_review = { enabled = false },
  review_comment = { save = { "<C-CR>", "<C-s>" }, sign = true, blocks = false },
}

local current = vim.deepcopy(DEFAULTS)

---@param options changeset.Options
local function validate(options)
  vim.validate("keymaps", options.keymaps, "table")
  vim.validate("layout", options.layout, "table")
  vim.validate("pr_review", options.pr_review, "table")
  vim.validate("review_comment", options.review_comment, "table")
  for action, lhs in pairs(options.keymaps) do
    vim.validate("keymaps." .. action, lhs, function(v)
      return v == false or (type(v) == "string" and v ~= "")
    end, "non-empty string or false")
  end
  vim.validate("layout.min_file_width", options.layout.min_file_width, "number")
  vim.validate("pr_review.enabled", options.pr_review.enabled, "boolean")
  vim.validate("review_comment.save", options.review_comment.save, function(v)
    -- `vim.islist({})` is true, and an empty list would leave no way to save.
    return vim.islist(v)
      and #v > 0
      and vim.iter(v):all(function(lhs)
        return type(lhs) == "string" and lhs ~= ""
      end)
  end, "non-empty list of non-empty strings")
  vim.validate("review_comment.sign", options.review_comment.sign, "boolean")
  vim.validate("review_comment.blocks", options.review_comment.blocks, "boolean")
end

---Lay `opts` over the defaults, not over the last call's. On a bad value, raise an error naming the option and keep what was in force.
---@param opts changeset.Config?
function M.setup(opts)
  vim.validate("opts", opts, "table", true)
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), opts or {})
  validate(merged)
  current = merged
end

---The options in force: what the last setup() asked for, not whether PR Review Mode is on. Read-only.
---@return changeset.Options
function M.get()
  return current
end

return M
