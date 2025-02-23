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
--  Plugin State and Commands
--]]
local state = {
  sarif_logs = {},
  table_widget = {},
  detail_widget = {},
  window_configs = {},
}

local function create_window_configurations()
  local width = vim.o.columns - 8
  local height = vim.o.lines - 4
  local half_height = math.floor(height/2)
  state.window_configs["table"] = {
    relative = "editor",
    width = width,
    height = half_height - 3,
    style = "minimal",
    border = "single",
    col = 4,
    row = 2,
    zindex = 1,
  }
  state.window_configs["detail"] = {
    relative = "editor",
    width = width,
    height = height - half_height,
    style = "minimal",
    border = "single",
    col = 4,
    row = 2 + half_height,
    zindex = 1,
  }
end

local function create_window_and_buffer(window_config)
  local buffer = vim.api.nvim_create_buf(false, true)
  local window = vim.api.nvim_open_win(buffer, true, window_config)
  vim.api.nvim_win_set_config(window, window_config)
  return window, buffer
end

local render_sarif_window

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
  render_sarif_window()
end

function TableWidget:goto_prev_row(self)
  if self.current_row > 1 then
    self.current_row = self.current_row - 1
  end
  render_sarif_window()
end

--[[
--  DetailWidget class
--]]
local DetailWidget = {}
DetailWidget.__index = DetailWidget
DetailWidget.new = function(window, buffer)
  return {
    data = {},
    window = window,
    buffer = buffer,
    width = vim.api.nvim_win_get_width(window),
    height = vim.api.nvim_win_get_height(window),
  }
end

function DetailWidget:render(self, result)
  local lines = {}
  table.insert(lines, "Message     : " .. result.level .. "\t" .. result.message)
  table.insert(lines, "File        : " .. result.file .. ":" .. result.start_position[1])
  vim.api.nvim_buf_set_lines(self.buffer, 0, -1, false, {}) -- Clear buffer
  vim.api.nvim_buf_set_lines(self.buffer, 0, 0, false, lines)
end

render_sarif_window = function()
  TableWidget:render(state.table_widget)
  local current_row = state.table_widget.current_row
  local current_result = state.table_widget.data[current_row]
  DetailWidget:render(state.detail_widget, current_result)
end

local function close_sarif_window()
  vim.api.nvim_win_close(state.table_widget.window, true)
  vim.api.nvim_win_close(state.detail_widget.window, true)
end

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
  close_sarif_window()
  vim.cmd('edit ' .. file)
  vim.cmd('call cursor(' .. tostring(start_position[1]) .. "," .. tostring(start_position[2]) .. ")")
  -- FIXME Highlight range
  -- FIXME If not start_col goto first non empty
end

M.view_sarif = function()
  -- Create a floating window to display results
  create_window_configurations()

  -- Parse SARIF logs and display a list of bugs to display
  local result_data = {}
  for _, sarif_log in pairs(state.sarif_logs) do
    for _, result in ipairs(SarifLog:get_results(sarif_log)) do
      table.insert(result_data, result)
    end
  end

  local table_window, table_buffer = create_window_and_buffer(state.window_configs["table"])
  state.table_widget = TableWidget.new(result_data, table_window, table_buffer, {"level", "file", "message"}, {5, 70, 80})
  buffer_keymap("q", table_buffer, function() close_sarif_window() end)
  buffer_keymap("k", table_buffer, function() TableWidget:goto_prev_row(state.table_widget) end)
  buffer_keymap("j", table_buffer, function() TableWidget:goto_next_row(state.table_widget) end)
  buffer_keymap("<Enter>", table_buffer, function() goto_result_location() end)

  local detail_window, detail_buffer = create_window_and_buffer(state.window_configs["detail"])
  state.detail_widget = DetailWidget.new(detail_window, detail_buffer)
  buffer_keymap("q", detail_buffer, function() close_sarif_window() end)
  buffer_keymap("k", detail_buffer, function() TableWidget:goto_prev_row(state.table_widget) end)
  buffer_keymap("j", detail_buffer, function() TableWidget:goto_next_row(state.table_widget) end)
  buffer_keymap("<Enter>", detail_buffer, function() goto_result_location() end)

  render_sarif_window()
end

return M
