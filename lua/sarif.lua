local M = {}

--[[
--  Result class
--]]
local Result = {}
Result.__index = Result
Result.new = function(json)
  local level = ""
  if json["level"] == "error" then
    level = "ERR  "
  elseif json["level"] == "warning" then
    level = "WARN "
  elseif json["level"] == "note" then
    level = "INFO "
  end

  return {
    json = json,
    level = level,
    message = json["message"]["text"],
  }
end

function Result:print(self)
  -- FIXME handle other message types and placeholders
  return self.level .. self.json["locations"][1]["physicalLocation"]["artifactLocation"]["uri"] .. " : ".. self.message
end

--[[
--  Run class
--]]
local Run = {}
Run.__index = Run
Run.new = function(json)
  local results = {}
  -- Get a list of all results
  for _, result in ipairs(json["results"]) do
    table.insert(results, Result.new(result))
  end

  return {
    json = json,
    results = results,
  }
end

function Run:get_results(self)
    return self.results
end

--[[
--  SarifLog class
--]]
local SarifLog = {}
SarifLog.__index = SarifLog
SarifLog.new = function(filename)
  -- Load the file and decode as JSON
  local ok, file_contents = pcall(vim.fn.readfile, filename)
  if not ok then
    vim.print("Error opening file " .. filename)
    return
  end
  local ok, json = pcall(vim.fn.json_decode, file_contents)
  if not ok then
    vim.print("Error while loading file: " .. sarif_log)
    return
  end

  -- Get a list of all runs
  local runs = {}
  for _, run in ipairs(json["runs"]) do
    table.insert(runs, Run.new(run))
  end

  return {
    filename = filename,
    json = json,
    runs = runs,
  }
end

function SarifLog:get_results(self)
  local results = {}
  for _, run in ipairs(self.runs) do
    for _, result in ipairs(Run:get_results(run)) do
      table.insert(results, result)
    end
  end
  return results
end



--[[
--  Plugin State and Commands
--]]
local state = {
  sarif_logs = {}
}

M.load_sarif_file = function(opts)
  filename = opts[1]
  local sarif_log = SarifLog.new(filename)
  if sarif_log then
    state.sarif_logs[filename] = sarif_log
    vim.print("Loaded SARIF log " .. filename .. " successfully")
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
  local result_list = {}
  for _, sarif_log in pairs(state.sarif_logs) do
    for _, result in ipairs(SarifLog:get_results(sarif_log)) do
      table.insert(result_list, Result:print(result))
    end
  end
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, result_list)

  -- Set some keybindings for the buffer
  buffer_keymap("q", buf, function() vim.api.nvim_win_close(win, true) end)
end

return M
