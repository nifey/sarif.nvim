vim.api.nvim_create_user_command("SarifLoad", function(opts)
  require("sarif").load_sarif_file(opts.fargs)
end, {
  nargs = 1,
})

vim.api.nvim_create_user_command("SarifView", function()
  require("sarif").view_sarif()
end, {})

vim.api.nvim_create_user_command("SarifCodeFlowNext", function()
  require("sarif").goto_next_flow_location()
end, {})

vim.api.nvim_create_user_command("SarifCodeFlowPrev", function()
  require("sarif").goto_prev_flow_location()
end, {})
