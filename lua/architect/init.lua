-- architect/init.lua
-- Entry point. Call require("architect").setup({}) in your lazy spec.

local M = {}

M.config = {
  openai_api_key = vim.env.OPENAI_API_KEY or "",
  model          = "gpt-4o",
  memory_dir     = ".nvim/architect",
  auto_save      = true,
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  if M.config.openai_api_key == "" then
    vim.notify("[architect] OPENAI_API_KEY not set.", vim.log.levels.WARN)
  end

  vim.api.nvim_create_user_command("Architect", function(args)
    local cmd = args.args
    if cmd == "" or cmd == "open" then
      require("architect.ui").open()
    elseif cmd == "status" then
      require("architect.ui").show_status()
    elseif cmd == "reset" then
      require("architect.memory").reset()
      vim.notify("[architect] Project memory reset.", vim.log.levels.INFO)
    end
  end, {
    nargs = "?",
    complete = function() return { "open", "status", "reset" } end,
    desc = "Architect AI workflow",
  })

  vim.keymap.set("n", "<leader>ar", "<cmd>Architect<CR>",
    { desc = "Architect: open", silent = true })
end

return M
