---Reachable as `support.cursor` only because `tests/minimal_init.lua` puts `tests/`
---on `package.path`.
local M = {}

---Whether 'guicursor' draws the normal-mode cursor in a fully blended group, which
---the TUI takes as its cue to hide the terminal's cursor.
---@return boolean
function M.hidden()
  local group ---@type string?
  for _, entry in ipairs(vim.opt.guicursor:get()) do
    local modes, args = entry:match("^(.-):(.*)$")
    if modes == "a" or vim.tbl_contains(vim.split(modes, "-"), "n") then
      for _, arg in ipairs(vim.split(args, "-")) do
        -- "Cursor/lCursor" names the group with and without a language mapping.
        local name = arg:match("^[^/]+")
        if name and vim.fn.hlexists(name) == 1 then
          group = name
        end
      end
    end
  end
  return group ~= nil and vim.api.nvim_get_hl(0, { name = group, link = false }).blend == 100
end

return M
