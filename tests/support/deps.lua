---The plugins the specs load, luacov for `mise run coverage` and nvim-treesitter for
---`mise run parsers`, checked out under `.tests/deps` at the revisions pinned below,
---so the suite does not depend on what the editor happens to have installed.
---`nvim -l tests/support/deps.lua` installs them; `require("support.deps")` only
---locates them.
local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h:h")

local M = {}

---@type string
M.dir = root .. "/.tests/deps"

---@class support.deps.Pin
---@field src string
---@field rev string

---Where the dependency `name` is checked out.
---@param name string
---@return string
function M.path(name)
  return M.dir .. "/" .. name
end

---The environment without GIT_* variables: a git hook exports GIT_DIR, which
---would point every command below at the repository being committed.
---@return table<string, string>
local function git_env()
  local env = vim.fn.environ()
  for name in pairs(env) do
    if name:match("^GIT_") then
      env[name] = nil
    end
  end
  return env
end

---Check each dependency out under `dir` at its pinned revision, fetching only the
---ones whose checkout is missing or elsewhere.
---@param pins table<string, support.deps.Pin> Keyed by directory name.
---@param dir string
---@return string[] errors One `name: reason` per dependency that failed.
function M.sync(pins, dir)
  local env = git_env()
  local jobs = {}
  for name, pin in pairs(pins) do
    local path = dir .. "/" .. name
    local head = vim.system({ "git", "-C", path, "rev-parse", "HEAD" }, { env = env, clear_env = true }):wait()
    if vim.trim(head.stdout or "") ~= pin.rev then
      vim.fn.mkdir(path, "p")
      local script = 'git init -q && git fetch -q --depth 1 "$1" "$2" && git checkout -q --detach FETCH_HEAD'
      jobs[name] = vim.system(
        { "sh", "-c", script, "sh", pin.src, pin.rev },
        { cwd = path, env = env, clear_env = true, text = true }
      )
    end
  end

  local errors = {}
  for name, job in pairs(jobs) do
    local result = job:wait()
    if result.code ~= 0 then
      table.insert(errors, name .. ": " .. vim.trim(result.stderr))
    end
  end
  return errors
end

---Sync every dependency to its pin, raising if any failed.
function M.install()
  -- Keep in sync with .luarc.check.json's workspace.library, which lists every pin but luacov.
  local pins = {
    ["plenary.nvim"] = {
      src = "https://github.com/nvim-lua/plenary.nvim",
      rev = "74b06c6c75e4eeb3108ec01852001636d85a932b",
    },
    ["nvim-treesitter"] = {
      src = "https://github.com/nvim-treesitter/nvim-treesitter",
      rev = "728e031f6b11d03d1f0708b7dc4fb0f1d9c8a137",
    },
    ["mini.icons"] = {
      src = "https://github.com/nvim-mini/mini.icons",
      rev = "e56797f90192d81f1fda02e662fc3e8e3d775027",
    },
    ["nvim-web-devicons"] = {
      src = "https://github.com/nvim-tree/nvim-web-devicons",
      rev = "58447c1fca354bbf184425e4a8d01deecbd6f3c4",
    },
    ["mini.pick"] = { src = "https://github.com/nvim-mini/mini.pick", rev = "8c1f75f8ddd8c9f75d07ed2ab5718d2c3cb65a66" },
    ["gitsigns.nvim"] = {
      src = "https://github.com/lewis6991/gitsigns.nvim",
      rev = "070a5d7b985546cc57e1fc61e5bc507fecac6045",
    },
    luacov = { src = "https://github.com/lunarmodules/luacov", rev = "b1f9eae400da976b93edb7f94cf5d05f538a0655" }, -- v0.17.0
  }
  local errors = M.sync(pins, M.dir)
  if #errors > 0 then
    error(table.concat(errors, "\n"), 0)
  end
end

if arg and arg[0] and vim.fn.fnamemodify(arg[0], ":p") == vim.fn.fnamemodify(this, ":p") then
  M.install()
end

return M
