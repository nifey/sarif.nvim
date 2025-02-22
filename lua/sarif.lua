local M = {}

M.load_sarif_file = function(opts)
  filename = opts[1]
  local ok, file_contents = pcall(vim.fn.readfile, filename)
  if not ok then
    vim.print("Error opening file " .. filename)
    return
  end

  local ok, sarif_log = pcall(vim.fn.json_decode, file_contents)
  if not ok then
    vim.print("Error while loading file: " .. sarif_log)
    return
  end

  vim.print("Loaded SARIF log successfully :")
  vim.print(sarif_log)
end

return M
