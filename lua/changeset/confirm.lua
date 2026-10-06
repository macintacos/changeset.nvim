---Yes/no questions, asked through `vim.ui.select` so a picker such as mini.pick draws them.
local M = {}

---Asks `question`, calling `yes` only once the user chooses Yes. No is listed first, so a stray
---<CR> typed ahead declines. `yes` runs once the select UI has closed:
---mini.pick answers while its window is still open, then takes focus back from any window `yes` opened.
---@param question string
---@param yes fun()
function M.ask(question, yes)
  vim.ui.select({ "No", "Yes" }, { prompt = question }, function(choice)
    if choice == "Yes" then
      vim.schedule(yes)
    end
  end)
end

return M
