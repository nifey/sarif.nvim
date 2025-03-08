local M = {}

local state = {
  sarif_logs = {},
  results = {},
  current_row = 1,
  current_scroll_window_start_row = 1,
  sarif_comments = {},
  table_widget = {},
  detail_widget = {},
  window_configs = {},
}

--[[
--  Result class
--]]
local Result = {}
Result.__index = Result
Result.new = function(json, log_id, run_id, result_id)

  local filename, start_position, end_position
  if #json["locations"] >= 1 then
    filename = json["locations"][1]["physicalLocation"]["artifactLocation"]["uri"]
    if json["locations"][1]["physicalLocation"]["region"] then
      start_position = {
        json["locations"][1]["physicalLocation"]["region"]["startLine"] or 0, 
        json["locations"][1]["physicalLocation"]["region"]["startColumn"] or 0, 
      }
      end_position = {
        json["locations"][1]["physicalLocation"]["region"]["endLine"] or start_position[1], 
        json["locations"][1]["physicalLocation"]["region"]["endColumn"] or start_position[2], 
      }
    else
      start_position = {0, 0}
      end_position = {0, 0}
    end
  end

  local rule_id
  local rule_index
  if json["ruleIndex"] then
    rule_index = json["ruleIndex"]
  elseif json["rule"] and json["rule"]["index"] then
    rule_index = json["rule"]["index"]
  end
  if not rule_index then
    rule_id = json["ruleId"]
    for index, rule in ipairs(state.sarif_logs[log_id].runs[run_id].rules) do
      if rule_id == rule["id"] then
        rule_index = index
        break
      end
    end
  else
    rule_index = rule_index + 1 -- To convert to 1 based indexing
    rule_id = state.sarif_logs[log_id].runs[run_id].rules[rule_index]['id']
  end

  local level
  if json["level"] then
    level = json["level"]
  else
    -- If the level is not specified in the Run, get it from the rule
    local rule_data = state.sarif_logs[log_id].runs[run_id].rules[rule_index]
    if rule_data["defaultConfiguration"] and rule_data["defaultConfiguration"]["level"] then
      level = rule_data["defaultConfiguration"]["level"]
    end
  end
  if level == "error" then
    level = "ERR"
  elseif level == "warning" then
    level = "WARN"
  elseif level == "note" then
    level = "INFO"
  end

  state.sarif_logs[log_id].runs[run_id].results[result_id] = {
    id = {log_id, run_id, result_id},
    json = json,
    level = level,
    start_position = start_position,
    end_position = end_position,
    file = filename,
    message = json["message"]["text"],
    rule_id = rule_id,
    rule_index = rule_index,
  }
end

--[[
--  Run class
--]]
local Run = {}
Run.__index = Run
Run.new = function(json, log_id, run_id)
  state.sarif_logs[log_id].runs[run_id] = {}
  local run = state.sarif_logs[log_id].runs[run_id]
  run.json = json

  local tool = json["tool"]["driver"]["name"]
  if json["tool"]["driver"]["version"] then
    tool = tool .. ((" " .. json["tool"]["driver"]["version"]) or "")
  end
  if json["tool"]["driver"]["informationUri"] then
    tool = tool .. ((" (" .. json["tool"]["driver"]["informationUri"] .. ")") or "")
  end
  run.tool = tool

  local rules = {}
  for rule_index, rule in ipairs(json["tool"]["driver"]["rules"]) do
    rules[rule_index] = rule
  end
  run.rules = rules

  local artifacts = {}
  if json["artifacts"] then
    for artifact_index, artifact in ipairs(json["artifacts"]) do
      artifacts[artifact_index] = artifact
    end
  end
  run.artifacts = artifacts

  run.results = {}
  -- Get a list of all results
  for result_id, result in ipairs(json["results"]) do
    Result.new(result, log_id, run_id, result_id)
  end
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
    vim.print("Error while loading file: " .. filename)
    return
  end

  -- Load the .sarifexplorer file if available
  local comment_filename = filename .. ".sarifexplorer"
  if vim.fn.filereadable(comment_filename) then
    local ok, comment_file_contents = pcall(vim.fn.readfile, comment_filename)
    if ok then
      local ok, comments_json = pcall(vim.fn.json_decode, comment_file_contents)
      if ok then
        state.sarif_comments[filename] = comments_json
      end
    end
  end
  if not state.sarif_comments[filename] then
    state.sarif_comments[filename] = {}
    state.sarif_comments[filename]["resultIdToNotes"] = {}
    state.sarif_comments[filename]["hiddenRules"] = {}
  end

  state.sarif_logs[filename] = {}
  state.sarif_logs[filename].json = json
  state.sarif_logs[filename].runs = {}
  -- Get a list of all runs
  local runs = {}
  if json["runs"] then
    for run_id, run in ipairs(json["runs"]) do
      Run.new(run, filename, run_id)
    end
  end

  vim.print("Loaded SARIF log " .. filename .. " successfully")
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
--  Plugin Commands
--]]

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
TableWidget.new = function(data, current_row, scroll_window_start_row, window, buffer, fields, fields_col_size)
  return {
    data = data,
    window = window,
    buffer = buffer,
    width = vim.api.nvim_win_get_width(window),
    height = vim.api.nvim_win_get_height(window),
    current_row = current_row,
    scroll_window_start_row = scroll_window_start_row,
    number_of_rows = #data,
    fields = fields,
    fields_col_size = fields_col_size,
  }
end

function TableWidget:render(self)
  local lines = {}
  for i, rowdata in ipairs(self.data) do
    if i >= self.scroll_window_start_row and i <= self.scroll_window_start_row + self.height - 2 then
      local line = ""
      if i == self.current_row then
        line = line .. ">"
      else
        line = line .. " "
      end
      for i, field in ipairs(self.fields) do
        local field_data
        if rowdata[field] then
          field_data = string.sub(rowdata[field], 1, self.fields_col_size[i])
        else
          field_data = ""
        end

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
  end
  vim.api.nvim_buf_set_lines(self.buffer, 0, -1, false, {}) -- Clear buffer
  vim.api.nvim_buf_set_lines(self.buffer, 0, 0, false, lines)
end

function TableWidget:goto_next_row(self)
  if self.current_row < self.number_of_rows then
    self.current_row = self.current_row + 1
    if self.current_row > self.scroll_window_start_row + self.height - 2 then
      self.scroll_window_start_row = self.scroll_window_start_row + 1
    end
  end
  render_sarif_window()
end

function TableWidget:goto_prev_row(self)
  if self.current_row > 1 then
    self.current_row = self.current_row - 1
    if self.current_row < self.scroll_window_start_row then
      self.scroll_window_start_row = self.scroll_window_start_row - 1
    end
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
  local log_id = result.id[1]
  local run_id = result.id[2]
  local result_id = result.id[3]
  table.insert(lines, "Message     : " .. result.level .. "\t" .. result.message)
  if result.file then
    if result.start_position then
      table.insert(lines, "File        : " .. result.file .. ":" .. result.start_position[1])
    else
      table.insert(lines, "File        : " .. result.file)
    end
  end
  table.insert(lines, "SARIF log   : " .. result.id[1])
  table.insert(lines, "Reported by : " .. state.sarif_logs[log_id].runs[run_id].tool)
  if result.rule_index then
    local rule = state.sarif_logs[log_id].runs[run_id].rules[result.rule_index]
    table.insert(lines, "Rule        : " .. result.rule_id)
    if rule["shortDescription"] then
      table.insert(lines, "              " .. rule["shortDescription"]["text"])
    end
    if rule["fullDescription"] then
      if not rule["shortDescription"] or rule["shortDescription"]["text"] ~= rule["fullDescription"]["text"] then
        for line in string.gmatch(rule["fullDescription"]["text"], "[^\n]+") do
          table.insert(lines, "              " .. line)
        end
      end
    end
    if rule["helpUri"] then
      table.insert(lines, "Help URI    : " .. rule["helpUri"])
    end
  end

  -- Display state and comments
  local result_comment_data = state.sarif_comments[log_id]["resultIdToNotes"] or {}
  local comments = result_comment_data[tostring(run_id-1) .. "|" .. tostring(result_id-1)]
  if comments then
    local result_status
    if comments["status"] == 1 then
      result_status = "False positive"
    elseif comments["status"] == 2 then
      result_status = "True positive"
    end
    table.insert(lines, "")
    table.insert(lines, "")
    if result_status then
      table.insert(lines, "State       : " .. result_status)
    else
      table.insert(lines, "")
    end
    if comments["comment"] then
      table.insert(lines, "Comments    : " .. comments["comment"])
    end
  end

  vim.api.nvim_buf_set_lines(self.buffer, 0, -1, false, {}) -- Clear buffer
  vim.api.nvim_buf_set_lines(self.buffer, 0, 0, false, lines)
end

render_sarif_window = function()
  TableWidget:render(state.table_widget)
  local current_row = state.table_widget.current_row
  local current_result = state.table_widget.data[current_row]
  if current_result then
    DetailWidget:render(state.detail_widget, current_result)
  end
end

local function close_sarif_window()
  state.current_row = state.table_widget.current_row
  state.current_scroll_window_start_row = state.table_widget.scroll_window_start_row
  vim.api.nvim_win_close(state.table_widget.window, true)
  vim.api.nvim_win_close(state.detail_widget.window, true)
end

M.load_sarif_file = function(opts)
  filename = opts[1]
  SarifLog.new(filename) -- Create a new SARIFLog and add to state.sarif_logs
  -- Load list of results to state
  state.results = {}
  for _, sarif_log in pairs(state.sarif_logs) do
    for _, result in ipairs(SarifLog:get_results(sarif_log)) do
      table.insert(state.results, result)
    end
  end
  table.sort(state.results, function(a, b)
    if a.file == b.file then
      if a.rule_id and b.rule_id then
        return a.rule_id < b.rule_id
      else
        return a.rule_id == nil
      end
    else
      return a.file < b.file
    end
  end)
end

local buffer_keymap = function(key, buf, command)
  vim.keymap.set("n", key, command, {buffer = buf})
end

local function goto_result_location()
  local current_row = state.table_widget.current_row
  local file = state.table_widget.data[current_row].file
  if not file then return end
  local start_position = state.table_widget.data[current_row].start_position
  close_sarif_window()
  vim.cmd('edit ' .. file)
  vim.cmd('call cursor(' .. tostring(start_position[1]) .. "," .. tostring(start_position[2]) .. ")")
  -- FIXME Highlight range
  -- FIXME If not start_col goto first non empty
end

local function save_comments_file()
  local current_result_id = state.table_widget.data[state.table_widget.current_row].id
  local log_id = current_result_id[1]
  local sarif_comments = state.sarif_comments[log_id]
  if sarif_comments ~= {} then
    local file_contents = vim.fn.json_encode(sarif_comments)
    vim.fn.writefile({file_contents}, filename .. ".sarifexplorer")
  end
end

local function get_current_result_comment_data()
  local current_result_id = state.table_widget.data[state.table_widget.current_row].id
  local log_id = current_result_id[1]
  local run_id = current_result_id[2]
  local result_id = current_result_id[3]
  local id_string = tostring(run_id - 1) .. "|" .. tostring(result_id - 1)
  local result_comment_data = state.sarif_comments[log_id]["resultIdToNotes"][id_string] or {}
  if not result_comment_data then
    state.sarif_comments[log_id]["resultIdToNotes"][id_string] = {}
    result_comment_data = {}
  end
  return result_comment_data
end

local function set_current_result_comment_data(data)
  local current_result_id = state.table_widget.data[state.table_widget.current_row].id
  local log_id = current_result_id[1]
  local run_id = current_result_id[2]
  local result_id = current_result_id[3]
  local id_string = tostring(run_id - 1) .. "|" .. tostring(result_id - 1)
  state.sarif_comments[log_id]["resultIdToNotes"][id_string] = data
end

local function toggle_result_state()
  local result_comment_data = get_current_result_comment_data()
  local result_status = result_comment_data["status"] or 0
  result_status = (result_status + 1) % 3
  result_comment_data["status"] = result_status
  set_current_result_comment_data(result_comment_data)
  save_comments_file()
  render_sarif_window()
end

local function edit_result_comment()
  local result_comment_data = get_current_result_comment_data()
  local comment = result_comment_data["comment"] or ""
  comment = vim.fn.input({ prompt = 'Comment: ', default = comment})
  result_comment_data["comment"] = comment
  set_current_result_comment_data(result_comment_data)
  save_comments_file()
  render_sarif_window()
end

M.view_sarif = function()
  -- Create a floating window to display results
  create_window_configurations()

  local table_window, table_buffer = create_window_and_buffer(state.window_configs["table"])
  state.table_widget = TableWidget.new(state.results, state.current_row, state.current_scroll_window_start_row, table_window, table_buffer, {"level", "file", "message"}, {5, 70, 80})
  buffer_keymap("q", table_buffer, close_sarif_window)
  buffer_keymap("k", table_buffer, function() TableWidget:goto_prev_row(state.table_widget) end)
  buffer_keymap("j", table_buffer, function() TableWidget:goto_next_row(state.table_widget) end)
  buffer_keymap("l", table_buffer, toggle_result_state)
  buffer_keymap("i", table_buffer, edit_result_comment)
  buffer_keymap("<Enter>", table_buffer, function() goto_result_location() end)

  local detail_window, detail_buffer = create_window_and_buffer(state.window_configs["detail"])
  state.detail_widget = DetailWidget.new(detail_window, detail_buffer)
  buffer_keymap("q", detail_buffer, close_sarif_window)
  buffer_keymap("k", detail_buffer, function() TableWidget:goto_prev_row(state.table_widget) end)
  buffer_keymap("j", detail_buffer, function() TableWidget:goto_next_row(state.table_widget) end)
  buffer_keymap("l", detail_buffer, toggle_result_state)
  buffer_keymap("i", detail_buffer, edit_result_comment)
  buffer_keymap("<Enter>", detail_buffer, function() goto_result_location() end)

  render_sarif_window()
end

return M
