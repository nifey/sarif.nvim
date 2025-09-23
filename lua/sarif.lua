local M = {}

local state = {
  sarif_logs = {},
  results = {},
  current_row = 1,
  current_flow_index = nil,
  current_scroll_window_start_row = 1,
  sarif_comments = {},
  table_widget = {},
  detail_widget = {},
  window_configs = {},
}

local function substitute_placeholders(string, arguments)
  for index, value in ipairs(arguments) do
    value = value:gsub("%%", "%%%%") -- To escape % characters the arguments
    string = string:gsub("{" .. tostring(index-1) .. "}", value)
  end
  return string
end

local function parse_location(location)
  -- Parses a Location JSON object and returns the filename, start line and start column
  local filename, start_position, end_position = "", {0, 0}, {0, 0}
  filename = location["physicalLocation"]["artifactLocation"]["uri"]
  if location["physicalLocation"]["region"] then
    start_position = {
      location["physicalLocation"]["region"]["startLine"] or 0, 
      location["physicalLocation"]["region"]["startColumn"] or 0, 
    }
    end_position = {
      location["physicalLocation"]["region"]["endLine"] or start_position[1], 
      location["physicalLocation"]["region"]["endColumn"] or start_position[2], 
    }
  end
  return filename, start_position, end_position
end

--[[
--  Result class
--]]
local Result = {}
Result.__index = Result
Result.new = function(json, log_id, run_id, result_id)

  local filename, start_position, end_position = "", {0, 0}, {0, 0}
  if json["locations"] and #json["locations"] >= 1 then
    filename, start_position, end_position = parse_location(json["locations"][1])
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

  local message
  local message_arguments = json["message"]["arguments"] or {}
  if json["message"]["text"] then
    message = substitute_placeholders(json["message"]["text"], message_arguments)
  elseif json["message"]["id"] then
    local message_id = json["message"]["id"]
    -- Try to get the message from rule.messageStrings
    if rule_index then
      local rule_message_strings = state.sarif_logs[log_id].runs[run_id].rules[rule_index]['messageStrings'] or nil
      if rule_message_strings then
        for _, rule_message_id in ipairs(rule_message_strings) do
          if message_id == rule_message_id then
            message = substitute_placeholders(rule_message_strings[rule_message_id]["text"], message_arguments)
            break
          end
        end
      end
    end
    if not message then
      -- Try to get the message from driver.globalMessageStrings
      local global_message_strings = state.sarif_logs[log_id].runs[run_id].json["tool"]["driver"]["globalMessageStrings"] or nil
      if global_message_strings then
        for global_message_id, message_object in pairs(global_message_strings) do
          if message_id == global_message_id then
            message = substitute_placeholders(message_object["text"], message_arguments)
            break
          end
        end
      end
    end
  end
  if not message then
    message = ""
  end

  local code_flows = {}
  if json["codeFlows"] then
    for _, code_flow in pairs(json["codeFlows"]) do
      for _, thread_flow in pairs(code_flow["threadFlows"]) do
        for _, location in pairs(thread_flow["locations"]) do
          if location then
            local flow_message = nil
            if location["message"] and location["message"]["text"] then
              flow_message = location["message"]["text"]
            end
            flow_filename, start_position, end_position = parse_location(location)
            table.insert(code_flows, {
              message = flow_message,
              filename = flow_filename,
              start_position = start_position,
              end_position = end_position,
            })
          end
        end
      end
    end
  end

  state.sarif_logs[log_id].runs[run_id].results[result_id] = {
    id = {log_id, run_id, result_id},
    json = json,
    level = level,
    start_position = start_position,
    end_position = end_position,
    file = filename,
    message = message,
    rule_id = rule_id,
    rule_index = rule_index,
    code_flows = code_flows,
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
    title = " SARIF Reports "
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

function TableWidget:set_table_data(self, data)
  self.data = data
  self.current_row = 1
  self.scroll_window_start_row = 1
  self.number_of_rows = #data
end

function TableWidget:render(self)
  local lines = {}
  for i, rowdata in ipairs(self.data) do
    if i >= self.scroll_window_start_row and i <= self.scroll_window_start_row + self.height - 2 then
      local line = ""
      if i == self.current_row then
        line = line .. "> "
      else
        line = line .. "  "
      end

      -- Add markers when the bug report is commented or marked
      local log_id = rowdata.id[1]
      local run_id = rowdata.id[2]
      local result_id = rowdata.id[3]
      local id_string = tostring(run_id - 1) .. "|" .. tostring(result_id - 1)
      local result_comment_data = state.sarif_comments[log_id]["resultIdToNotes"][id_string] or {}
      if result_comment_data then
        if result_comment_data["comment"] then
          line = line .. "*"
        else
          line = line .. " "
        end
        if result_comment_data["status"] then
          if result_comment_data["status"] == 1 then
            line = line .. "F"
          elseif result_comment_data["status"] == 2 then
            line = line .. "T"
          else
            line = line .. " "
          end
        else
          line = line .. " "
        end
      else
        line = line .. "  "
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
      line = string.sub(line, 1, self.width - 8)
      table.insert(lines, line)
    end
  end
  vim.api.nvim_buf_set_lines(self.buffer, 0, -1, false, {}) -- Clear buffer
  vim.api.nvim_buf_set_lines(self.buffer, 0, 0, false, lines)
end

function TableWidget:goto_next_row(self)
  if self.current_row < self.number_of_rows then
    self.current_row = self.current_row + 1
    self.current_flow_index = nil
    if self.current_row > self.scroll_window_start_row + self.height - 2 then
      self.scroll_window_start_row = self.scroll_window_start_row + 1
    end
  end
  render_sarif_window()
end

function TableWidget:goto_prev_row(self)
  if self.current_row > 1 then
    self.current_row = self.current_row - 1
    self.current_flow_index = nil
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
    scroll_window_start_row = 1,
    scroll_window_limit = 1,
  }
end

function DetailWidget:render(self, result)
  local lines = {}
  local log_id = result.id[1]
  local run_id = result.id[2]
  local result_id = result.id[3]
  if result.file ~= "" then
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

  table.insert(lines, "")
  local message = "Message     : " .. result.level .. "\t" .. result.message
  for line in string.gmatch(message, "[^\n]+") do
    table.insert(lines, line)
  end

  self.scroll_window_limit = #lines
  local visible_lines = {}
  for i, line in ipairs(lines) do
    if i >= self.scroll_window_start_row and i <= self.scroll_window_start_row + self.height - 2 then
      table.insert(visible_lines, line)
    end
  end

  vim.api.nvim_buf_set_lines(self.buffer, 0, -1, false, {}) -- Clear buffer
  vim.api.nvim_buf_set_lines(self.buffer, 0, 0, false, visible_lines)
end

function DetailWidget:goto_next_row(self)
  if self.scroll_window_start_row < self.scroll_window_limit - self.height + 2 then
    self.scroll_window_start_row = self.scroll_window_start_row + 1
  end
  render_sarif_window()
end

function DetailWidget:goto_prev_row(self)
  if self.scroll_window_start_row > 1 then
    self.scroll_window_start_row = self.scroll_window_start_row - 1
  end
  render_sarif_window()
end

render_sarif_window = function()
  TableWidget:render(state.table_widget)
  local current_row = state.table_widget.current_row
  local current_result = state.table_widget.data[current_row]
  if current_result then
    DetailWidget:render(state.detail_widget, current_result)
  end

  -- Update the title with the report count
  if state.table_widget.data and #state.table_widget.data > 0 then
    state.window_configs["table"].title = " SARIF Reports (" .. tostring(current_row) 
                  .. "/" .. tostring(#state.table_widget.data) .. ") "
  else
    state.window_configs["table"].title = " SARIF Reports "
  end
  vim.api.nvim_win_set_config(state.table_widget.window, state.window_configs["table"])
end

local function close_sarif_window()
  state.current_row = state.table_widget.current_row
  state.current_scroll_window_start_row = state.table_widget.scroll_window_start_row
  state.current_detail_view_scroll_start = state.detail_widget.scroll_window_start_row
  vim.api.nvim_win_close(state.table_widget.window, true)
  vim.api.nvim_win_close(state.detail_widget.window, true)
end

local sort_results_by_filename = function (a, b)
  if a.file == b.file then
    if a.rule_id and b.rule_id then
      return a.rule_id < b.rule_id
    else
      return a.rule_id == nil
    end
  else
    return a.file < b.file
  end
end

M.load_sarif_file = function(opts)
  filename = opts[1]
  SarifLog.new(filename) -- Create a new SARIFLog and add to state.sarif_logs
  -- Load list of results to state
  state.results = {}
  for _, sarif_log in pairs(state.sarif_logs) do
    for _, result in ipairs(SarifLog:get_results(sarif_log)) do
      local should_hide_result = false
      if result.rule_index then
        for _, hiddenRule in ipairs(state.sarif_comments[filename]["hiddenRules"]) do
          if hiddenRule == result.rule_id then
            should_hide_result = true
            break
          end
        end
      end
      if not should_hide_result then
        table.insert(state.results, result)
      end
    end
  end
  table.sort(state.results, sort_results_by_filename)
end

local buffer_keymap = function(key, command)
  vim.keymap.set("n", key, command, {buffer = state.table_widget.buffer})
  vim.keymap.set("n", key, command, {buffer = state.detail_widget.buffer})
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

M.goto_next_flow_location = function()
  local current_row = state.table_widget.current_row
  local code_flows = state.table_widget.data[current_row].code_flows
  if #code_flows >= 1 then
    if not state.current_flow_index then
      -- We are just starting the flow for this result
      state.current_flow_index = 1
    elseif state.current_flow_index < #code_flows then
      state.current_flow_index = state.current_flow_index + 1
    end

    -- Go to the current flow location
    local flow = code_flows[state.current_flow_index]
    if not flow.filename then return end
    vim.cmd('edit ' .. flow.filename)
    vim.cmd('call cursor(' .. tostring(flow.start_position[1]) .. "," .. tostring(flow.start_position[2]) .. ")")
    if flow.message then
      vim.cmd('echo "' .. flow.message .. '"')
    end
  end
end

M.goto_prev_flow_location = function()
  local current_row = state.table_widget.current_row
  local code_flows = state.table_widget.data[current_row].code_flows
  if #code_flows >= 1 then
    if not state.current_flow_index then
      -- We are just starting the flow for this result
      state.current_flow_index = 1
    elseif state.current_flow_index > 1 then
      state.current_flow_index = state.current_flow_index - 1
    end

    -- Go to the current flow location
    local flow = code_flows[state.current_flow_index]
    if not flow.filename then return end
    vim.cmd('edit ' .. flow.filename)
    vim.cmd('call cursor(' .. tostring(flow.start_position[1]) .. "," .. tostring(flow.start_position[2]) .. ")")
    if flow.message then
      vim.cmd('echo "' .. flow.message .. '"')
    end
  end
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

local function get_filtered_results_by_rule_type(search_string)
  -- Returns a data table with only the results that have 
  -- the given field matching with the search string
  local filtered_results = {}
  for _, result in ipairs(state.results) do
    if string.find(result.rule_id, search_string) then
      local should_hide_result = false
      if result.rule_index then
        for _, hiddenRule in ipairs(state.sarif_comments[filename]["hiddenRules"]) do
          if hiddenRule == result.rule_id then
            should_hide_result = true
            break
          end
        end
      end
      if not should_hide_result then
        table.insert(filtered_results, result)
      end
    end
  end
  table.sort(filtered_results, sort_results_by_filename)
  return filtered_results
end

local function filter_results_by_rule_type()
  search_string = vim.fn.input({ prompt = 'Filter results with type matching: '})
  TableWidget:set_table_data(state.table_widget, get_filtered_results_by_rule_type(search_string))
  render_sarif_window()
end

local function reset_filter()
  TableWidget:set_table_data(state.table_widget, state.results)
  render_sarif_window()
end

M.view_sarif = function()
  -- Create a floating window to display results
  create_window_configurations()

  local table_window, table_buffer = create_window_and_buffer(state.window_configs["table"])
  local detail_window, detail_buffer = create_window_and_buffer(state.window_configs["detail"])
  state.table_widget = TableWidget.new(state.results, state.current_row, 
                        state.current_scroll_window_start_row,
                        table_window, table_buffer,
                        {"level", "file", "message"}, {5, 40, 80})
  state.detail_widget = DetailWidget.new(detail_window, detail_buffer)

  -- Key bindings for the Viewer
  buffer_keymap("q", close_sarif_window)
  buffer_keymap("k", function() TableWidget:goto_prev_row(state.table_widget) end)
  buffer_keymap("j", function() TableWidget:goto_next_row(state.table_widget) end)
  buffer_keymap("h", function() DetailWidget:goto_prev_row(state.detail_widget) end)
  buffer_keymap("l", function() DetailWidget:goto_next_row(state.detail_widget) end)
  buffer_keymap("m", toggle_result_state)
  buffer_keymap("i", edit_result_comment)
  buffer_keymap("<Enter>", function() goto_result_location() end)
  buffer_keymap("/t", filter_results_by_rule_type)
  buffer_keymap("/c", reset_filter)

  render_sarif_window()
end

return M
