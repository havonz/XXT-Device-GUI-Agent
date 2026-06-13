local Parser = require("agent_parser")

local M = {}

function M.new()
    return {
        records = {},
        compressed_state = "",
    }
end

local function limit_text(text, max_chars)
    text = tostring(text or "")
    if #text <= max_chars then
        return text
    end
    local index = 1
    local last = 0
    while index <= #text and last < max_chars do
        local byte = string.byte(text, index)
        local size = 1
        if byte >= 240 then
            size = 4
        elseif byte >= 224 then
            size = 3
        elseif byte >= 192 then
            size = 2
        end
        if last + size > max_chars then
            break
        end
        last = last + size
        index = index + size
    end
    if last == 0 then
        return ""
    end
    return string.sub(text, 1, last)
end

local function text_field(action, key)
    local value = action and action[key]
    if value == nil then
        return "none"
    end
    value = tostring(value)
    if value == "" then
        return "none"
    end
    return limit_text(value, 800)
end

local function sanitized_action(action)
    if type(action) ~= "table" then
        return {}
    end
    local result = {}
    for key, value in pairs(action) do
        if type(value) == "string" then
            result[key] = limit_text(value, 800)
        else
            result[key] = value
        end
    end
    return result
end

local function action_to_json(action)
    return json.encode(sanitized_action(action)) or "{}"
end

function M.record_to_history(record)
    if type(record) ~= "table" then
        return ""
    end
    local action = record.action or {}
    local execution = record.execution or {}
    local lines = {
        "[STEP " .. tostring(record.step or "?") .. "]",
        "verify: " .. text_field(action, "verify"),
        "note: " .. text_field(action, "note"),
        "explain: " .. text_field(action, "explain"),
        "action: " .. action_to_json(action),
        "key_process: " .. text_field(action, "key_process"),
        "summary: " .. text_field(action, "summary"),
        "execution: " .. (json.encode(execution) or "{}"),
    }
    return table.concat(lines, "\n")
end

function M.build_history(config, memory)
    if type(memory) ~= "table" then
        return "暂无历史操作"
    end
    local parts = {}
    if type(memory.compressed_state) == "string" and memory.compressed_state ~= "" then
        parts[#parts + 1] = "以下是更早历史的压缩状态：\n" .. memory.compressed_state
    end

    local records = memory.records or {}
    local start_idx = #records - config.recent_history_steps + 1
    if start_idx < 1 then
        start_idx = 1
    end
    for i = start_idx, #records do
        parts[#parts + 1] = M.record_to_history(records[i])
    end
    if #parts == 0 then
        return "暂无历史操作"
    end
    return table.concat(parts, "\n\n")
end

function M.compress(config, memory, call_text_model)
    if not config.enable_state_compression or type(memory) ~= "table" then
        return nil
    end
    local records = memory.records or {}
    local compress_count = #records - config.state_compression_recent_window
    if compress_count <= 0 then
        return nil
    end

    local old_parts = {}
    for i = 1, compress_count do
        old_parts[#old_parts + 1] = M.record_to_history(records[i])
    end
    local prompt = [[
你是设备端 GUI Agent 的历史状态压缩器。请把较早步骤压缩成一段稳定状态，供后续动作决策使用。

要求：
1. 只输出压缩状态，不要预测下一步动作。
2. 必须保留用户任务、已完成进展、重要页面事实、用户介入结果、未解决风险、当前子目标。
3. 如果旧压缩状态与新增记录冲突，以新增记录为准。
4. 输出控制在 ]] .. tostring(config.state_compression_max_chars) .. [[ 字符以内。

旧压缩状态：
]] .. tostring(memory.compressed_state or "none") .. [[

新增较早步骤：
]] .. table.concat(old_parts, "\n\n")

    local compressed, err = call_text_model(prompt, math.min(config.max_tokens, 1200))
    if not compressed then
        return err
    end
    memory.compressed_state = limit_text(compressed, config.state_compression_max_chars)
    local kept = {}
    for i = compress_count + 1, #records do
        kept[#kept + 1] = records[i]
    end
    memory.records = kept
    return nil
end

local function point_signature(point)
    local x, y = Parser.point_value(point)
    if not x or not y then
        return "nil"
    end
    x = math.floor(x / 10 + 0.5) * 10
    y = math.floor(y / 10 + 0.5) * 10
    return tostring(x) .. "," .. tostring(y)
end

function M.action_signature(action)
    local action_type = Parser.normalize_action_type(Parser.field(action, "action", "Action", "action_type", "type"))
    if action_type == "CLICK" or action_type == "LONGPRESS" or action_type == "DOUBLECLICK" then
        return action_type .. ":" .. point_signature(Parser.field(action, "point", "Point"))
    end
    if action_type == "SLIDE" or action_type == "LONGPRESS_DRAG" then
        return action_type .. ":" .. point_signature(Parser.field(action, "point1", "Point1")) .. ">" .. point_signature(Parser.field(action, "point2", "Point2"))
    end
    if action_type == "SCROLL" then
        return action_type .. ":" .. tostring(Parser.field(action, "direction", "Direction") or "down")
    end
    if action_type == "AWAKE" or action_type == "OPENURL" or action_type == "TYPE" or action_type == "WAIT" or action_type == "HOTKEY" then
        return action_type .. ":" .. tostring(Parser.action_value(action) or Parser.field(action, "key", "Key") or "")
    end
    return action_type
end

function M.detect_repetition(config, memory, action)
    local records = (memory and memory.records) or {}
    local signature = M.action_signature(action)
    local action_type = Parser.normalize_action_type(Parser.field(action, "action", "Action", "action_type", "type"))
    local same_count = 1
    for i = #records, 1, -1 do
        local prev = records[i].action
        if M.action_signature(prev) ~= signature then
            break
        end
        same_count = same_count + 1
    end

    local threshold = config.same_action_loop_threshold
    if action_type == "CLICK" or action_type == "DOUBLECLICK" then
        threshold = config.click_loop_threshold
    elseif action_type == "SLIDE" or action_type == "SCROLL" then
        threshold = config.slide_loop_threshold
    end

    if same_count >= threshold then
        return "检测到连续重复动作 " .. signature .. " 已达到 " .. tostring(same_count) .. " 次。请远控确认当前页面状态，完成后点击完成。"
    end
    return nil
end

return M
