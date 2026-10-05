---Yes/no questions, asked through `vim.ui.select` so a picker such as mini.pick draws them.
local M = {}

---Asks `question`, calling `yes` only once the user chooses Yes. No is listed first, so a stray
---<CR>, typed while GitHub was answering, declines.
---@param question string
---@param yes fun()
function M.ask(question, yes)
  vim.ui.select({ "No", "Yes" }, { prompt = question }, function(choice)
    if choice == "Yes" then
      yes()
    end
  end)
end

return M
