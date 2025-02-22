local M = {}

--[[
--  Result class
--]]
local Result = {}
Result.__index = Result
Result.new = function(json)
  local level = ""
  if json["level"] == "error" then
    level = "ERR"
  elseif json["level"] == "warning" then
    level = "WARN"
  elseif json["level"] == "note" then
    level = "INFO"
  end

  local filename = json["locations"][1]["physicalLocation"]["artifactLocation"]["uri"]
  local start_position = {
    json["locations"][1]["physicalLocation"]["region"]["startLine"] or 0, 
    json["locations"][1]["physicalLocation"]["region"]["startColumn"] or 0, 
  }
  local end_position = {
    json["locations"][1]["physicalLocation"]["region"]["endLine"] or start_position[1], 
    json["locations"][1]["physicalLocation"]["region"]["endColumn"] or start_position[2], 
  }

  return {
    json = json,
    level = level,
    start_position = start_position,
    end_position = end_position,
    file = filename,
    message = json["message"]["text"],
  }
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
--  TableWidget class
--]]
local TableWidget = {}
TableWidget.__index = TableWidget
-- @param fields Ordered list of fields to display
-- @param fields_col_size Column size to use for each field
TableWidget.new = function(data, window, buffer, fields, fields_col_size)
  return {
    data = data,
    window = window,
    buffer = buffer,
    width = vim.api.nvim_win_get_width(window),
    height = vim.api.nvim_win_get_height(window),
    current_row = 1,
    number_of_rows = #data,
    fields = fields,
    fields_col_size = fields_col_size,
  }
end

function TableWidget:render(self)
  local lines = {}
  for i, rowdata in ipairs(self.data) do
    local line = ""
    if i == self.current_row then
      line = line .. ">"
    else
      line = line .. " "
    end
    for i, field in ipairs(self.fields) do
      local field_data = string.sub(rowdata[field], 1, self.fields_col_size[i])
      local field_data_len = #field_data
      line = line .. "\t" .. field_data
      if field_data_len < self.fields_col_size[i] then
        for _ = 1, self.fields_col_size[i] - field_data_len do
          line = line .. " "
        end
      end
    end
    line = string.sub(line, 1, self.width - 5)
    table.insert(lines, line)
  end
  vim.api.nvim_buf_set_lines(self.buffer, 0, -1, false, {}) -- Clear buffer
  vim.api.nvim_buf_set_lines(self.buffer, 0, 0, false, lines)
end

function TableWidget:goto_next_row(self)
  if self.current_row < self.number_of_rows then
    self.current_row = self.current_row + 1
  end
  TableWidget:render(self)
end

function TableWidget:goto_prev_row(self)
  if self.current_row > 1 then
    self.current_row = self.current_row - 1
  end
  TableWidget:render(self)
end


--[[
--  Plugin State and Commands
--]]
local state = {
  sarif_logs = {},
  table_widget = {},
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

local function goto_result_location()
  local current_row = state.table_widget.current_row
  local file = state.table_widget.data[current_row].file
  local start_position = state.table_widget.data[current_row].start_position
  local end_position = state.table_widget.data[current_row].end_position
  vim.api.nvim_win_close(state.table_widget.window, true)
  vim.cmd('edit ' .. file)
  vim.cmd('call cursor(' .. tostring(start_position[1]) .. "," .. tostring(start_position[2]) .. ")")
  -- FIXME Highlight range
  -- FIXME If not start_col goto first non empty
end

M.view_sarif = function()
  -- Create a floating window to display results
  local width = vim.o.columns
  local height = vim.o.lines
  local config = {
    relative = "editor",
    width = width - 8,
    height = height - 4,
    style = "minimal",
    border = "single",
    col = 4,
    row = 2,
    zindex = 1,
  }
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, config)
  vim.api.nvim_win_set_config(win, config)

  -- Parse SARIF logs and display a list of bugs to display
  local result_data = {}
  for _, sarif_log in pairs(state.sarif_logs) do
    for _, result in ipairs(SarifLog:get_results(sarif_log)) do
      table.insert(result_data, result)
    end
  end
  state.table_widget = TableWidget.new(result_data, win, buf, {"level", "file", "message"}, {5, 70, 80})
  TableWidget:render(state.table_widget)

  -- Set some keybindings for the buffer
  buffer_keymap("q", buf, function() vim.api.nvim_win_close(win, true) end)
  buffer_keymap("k", buf, function() TableWidget:goto_prev_row(state.table_widget) end)
  buffer_keymap("j", buf, function() TableWidget:goto_next_row(state.table_widget) end)
  buffer_keymap("<Enter>", buf, function() goto_result_location() end)
end

return M
