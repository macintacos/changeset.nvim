---Which symbol kinds the sidebar hides, remembered across Neovim sessions.
---
---Three scopes, narrowest first: this branch, this repository, everywhere. A
---scope counts as set by *having* a record, not by that record hiding anything,
---so a branch that hides nothing still overrides a repository that hides
---something — which is the only way "show me everything, just here" can be said.

local M = {}

---@class changeset.RepoPrefs
---@field kinds string[]? Set for the whole repository.
---@field branches table<string, string[]>? Set per branch.

---@class changeset.Prefs
---@field global string[]?
---@field repos table<string, changeset.RepoPrefs>?

---@alias changeset.Scope "global"|"repo"|"branch"

---Where the record lives. Under `state` rather than `cache`, unlike the symbol
---cache: nothing here can be derived again, so losing the file loses a choice.
---@return string
function M.path()
  return vim.fs.joinpath(vim.fn.stdpath("state"), "changeset", "filters.json")
end

---@param list string[]?
---@return table<string, true>? nil only when there is no record at all.
local function as_set(list)
  if not list then
    return nil
  end
  local set = {}
  for _, kind in ipairs(list) do
    set[kind] = true
  end
  return set
end

---@param set table<string, true>
---@return string[] Sorted, so saving the same choice twice writes the same bytes.
local function as_list(set)
  local list = vim.tbl_keys(set)
  table.sort(list)
  return list
end

---Drop the empty tables a clearing leaves behind, so the file stays legible.
---@param data changeset.Prefs
---@param root string
local function prune(data, root)
  local repo = data.repos[root]
  if vim.tbl_isempty(repo.branches or {}) then
    repo.branches = nil
  end
  if vim.tbl_isempty(repo) then
    data.repos[root] = nil
  end
  if vim.tbl_isempty(data.repos) then
    data.repos = nil
  end
end

---The kinds hidden for this branch of this repo, and the scope that decided it.
---@param data changeset.Prefs
---@param root string Absolute repo root.
---@param branch string
---@return table<string, true> hidden
---@return changeset.Scope? scope nil when no scope has a record.
function M.resolve(data, root, branch)
  local repo = (data.repos or {})[root] or {}
  for _, candidate in ipairs({
    { "branch", (repo.branches or {})[branch] },
    { "repo", repo.kinds },
    { "global", data.global },
  }) do
    local set = as_set(candidate[2])
    if set then
      return set, candidate[1]
    end
  end
  return {}, nil
end

---Record `hidden` at `scope`, clearing the narrower records that would shadow it.
---
---Without the clearing, saving "everywhere" from a repository that has its own
---record would change nothing here, and the word would be a lie. Only the
---records shadowing *this* repo and branch go; another repository's deliberate
---choice is none of this save's business.
---@param data changeset.Prefs Left unmodified.
---@param scope changeset.Scope
---@param root string
---@param branch string
---@param hidden table<string, true>
---@return changeset.Prefs
function M.apply(data, scope, root, branch, hidden)
  local out = vim.deepcopy(data)
  out.repos = out.repos or {}
  out.repos[root] = out.repos[root] or {}
  local repo = out.repos[root]

  if scope == "branch" then
    repo.branches = repo.branches or {}
    repo.branches[branch] = as_list(hidden)
  else
    if repo.branches then
      repo.branches[branch] = nil
    end
    if scope == "repo" then
      repo.kinds = as_list(hidden)
    else
      repo.kinds = nil
      out.global = as_list(hidden)
    end
  end

  prune(out, root)
  return out
end

---Read the record from `file`. Missing or corrupt file means nothing is hidden.
---@param file string
---@return changeset.Prefs
function M.load(file)
  local fd = io.open(file, "r")
  if not fd then
    return {}
  end
  local content = fd:read("*a")
  fd:close()
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then
    return {}
  end
  return data
end

---Overwrite `file` with `data`.
---@param file string
---@param data changeset.Prefs
---@return boolean written A choice that did not reach the disk is worth reporting.
function M.save(file, data)
  vim.fn.mkdir(vim.fs.dirname(file), "p")
  local fd = io.open(file, "w")
  if not fd then
    return false
  end
  fd:write(vim.json.encode(data))
  fd:close()
  return true
end

return M
