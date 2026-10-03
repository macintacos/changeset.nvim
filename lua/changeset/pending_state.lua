---Each PR's pending review as GitHub last answered, per repository and PR.
local build = require("changeset.build")
local pending_review = require("changeset.pending_review")

local M = {}

---GitHub's last answer for each PR, by `key`. A failed ask leaves it as it was.
---@type table<string, changeset.pending_review.Found>
local answers = {}

---Each repository's latest ask; an answer to any other is not kept, so an older reply can't overwrite a newer one.
---@type table<string, table>
local latest = {}

---@param root string
---@param number integer
---@return string
local function key(root, number)
  return root .. "\n" .. number
end

---"root\nbranch\npr" of the tree when last heard, so a rebuild of the same one fetches nothing.
---@type string?
local heard

---@type table<fun(), true>
local subscribers = {}

---GitHub's last answer for PR `number` at `root`.
---@param root string
---@param number integer
---@return changeset.pending_review.Found? found nil until GitHub has answered for that PR.
function M.get(root, number)
  return answers[key(root, number)]
end

---Asks GitHub for `root`'s PR and its pending review, keeping the answer while the tree is still on that PR.
---@param root string
---@param cb fun(err: string?, found: changeset.pending_review.Found?)? Called with the raw answer, kept or not.
function M.fetch(root, cb)
  local ask = {}
  latest[root] = ask
  pending_review.find(root, function(err, answer)
    local tree = build.current()
    if answer and latest[root] == ask and tree and tree.root == root and tree.pr == answer.pr.number then
      answers[key(root, answer.pr.number)] = answer
      for fn in pairs(subscribers) do
        fn()
      end
    end
    if cb then
      cb(err, answer)
    end
  end)
end

---Calls `fn` after each answer is kept. Subscribing again does nothing.
---@param fn fun()
function M.subscribe(fn)
  subscribers[fn] = true
end

-- Fires: every tree event. Fetches only when the tree's root, branch or PR is new, and only when it has a PR.
build.subscribe(function()
  local tree = build.current()
  local now = tree and table.concat({ tree.root, tree.branch, tostring(tree.pr) }, "\n")
  if now == heard then
    return
  end
  heard = now
  if tree and tree.pr then
    M.fetch(tree.root)
  end
end)

vim.api.nvim_create_autocmd("FocusGained", {
  group = vim.api.nvim_create_augroup("changeset.pending_state", { clear = true }),
  desc = "changeset: ask GitHub again for the PR's pending review, which may have changed on github.com",
  callback = function()
    local tree = build.current()
    if tree and tree.pr then
      M.fetch(tree.root)
    end
  end,
})

return M
