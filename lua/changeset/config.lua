---The user's options: the defaults, and what `setup()` made of them. Read when a module
---acts, never when it loads, so a later `setup()` reaches it.
local M = {}

---@class changeset.Config
---@field keymaps? changeset.Config.Keymaps The sidebar's keys, each a key or `false` to leave it unbound.
---@field layout? changeset.Config.Layout
---@field pr_review? changeset.Config.PrReview
---@field review_comment? changeset.Config.ReviewComment

---@class changeset.Config.Keymaps
---@field jump? string|false Go to this change. Default `<CR>`.
---@field jump_close? string|false Go to this change and close the tree. Default `<S-CR>`.
---@field jump_vsplit? string|false Go to this change in a vertical split. Default `<C-v>`.
---@field jump_split? string|false Go to this change in a split. Default `<C-x>`.
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
    jump_vsplit = "<C-v>",
    jump_split = "<C-x>",
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
  },
  layout = { min_file_width = 80 },
  pr_review = { enabled = false },
  review_comment = { save = { "<C-CR>", "<C-s>" }, sign = true, blocks = false },
}

local current = vim.deepcopy(DEFAULTS)
---@type string[]
local ignored = {}

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

---Splits `opts` into the options `defaults` has and the dotted paths of those it doesn't. A list is one option.
---@param opts table
---@param defaults table
---@param prefix string
---@return table known
---@return string[] unknown
local function split(opts, defaults, prefix)
  local known, unknown = {}, {}
  for key, value in pairs(opts) do
    local default = defaults[key]
    if default == nil then
      table.insert(unknown, prefix .. tostring(key))
    elseif type(default) == "table" and not vim.islist(default) and type(value) == "table" then
      local inner_unknown
      known[key], inner_unknown = split(value, default, prefix .. key .. ".")
      vim.list_extend(unknown, inner_unknown)
    else
      known[key] = value
    end
  end
  table.sort(unknown)
  return known, unknown
end

---`opts` split against the defaults.
---@param opts table
---@return table known
---@return string[] unknown
function M._split(opts)
  return split(opts, DEFAULTS, "")
end

---Lay `opts` over the defaults, not over the last call's. On a bad value, raise an error naming the option and keep
---what was in force. An option it doesn't know only warns, so a stale one can't stop startup.
---@param opts changeset.Config?
function M.setup(opts)
  vim.validate("opts", opts, "table", true)
  local known, unknown = M._split(opts or {})
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), known)
  validate(merged)
  current, ignored = merged, unknown
  if #unknown > 0 then
    -- Scheduled: setup() runs during startup, before a notifier set up later, such as mini.notify, replaces vim.notify.
    vim.schedule(function()
      vim.notify(
        ("Changeset: ignoring unknown options %s. See :help changeset.nvim-options"):format(table.concat(unknown, ", ")),
        vim.log.levels.WARN
      )
    end)
  end
end

---The options in force: what the last setup() asked for, not whether PR Review Mode is on. Read-only.
---@return changeset.Options
function M.get()
  return current
end

---The dotted paths of the options the last setup() didn't know, and left out of those in force.
---@return string[]
function M.unknown()
  return ignored
end

return M
