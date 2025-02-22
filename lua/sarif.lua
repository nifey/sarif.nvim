local M = {}

local state = {
  sarif_logs = {}
}

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
  else
    vim.print("Loaded SARIF log " .. filename .. " successfully")
    state.sarif_logs[filename] = sarif_log
  end
end

local buffer_keymap = function(key, buf, command)
  vim.keymap.set("n", key, command, {buffer = buf})
end

M.view_sarif = function()
  -- Create a floating window to display results
  local width = vim.o.columns
  local height = vim.o.lines
  local config = {
    relative = "editor",
    width = width - 2,
    height = height - 2,
    style = "minimal",
    col = 1,
    row = 1,
    zindex = 1,
  }
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, config)
  vim.api.nvim_win_set_config(win, config)

  -- Parse SARIF logs and display a list of bugs to display
  local bug_list = {}
  for _, sarif_log in pairs(state.sarif_logs) do
    for _, run in ipairs(sarif_log["runs"]) do
      for _, result in ipairs(run["results"]) do
        local message = ""
        if result["level"] == "error" then
          message = "ERR  "
        elseif result["level"] == "warning" then
          message = "WARN "
        elseif result["level"] == "note" then
          message = "INFO "
        end

        message = message .. result["locations"][1]["physicalLocation"]["artifactLocation"]["uri"]
        message = message .. " : ".. result["message"]["text"]
        table.insert(bug_list, message)
      end
    end
  end
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, bug_list)

  -- Set some keybindings for the buffer
  buffer_keymap("q", buf, function() vim.api.nvim_win_close(win, true) end)
end

return M
