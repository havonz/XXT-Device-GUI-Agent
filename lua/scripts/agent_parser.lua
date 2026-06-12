local M = {}

local function trim(text)
    text = tostring(text or "")
    return (string.gsub(text, "^%s*(.-)%s*$", "%1"))
end

local function parse_point_text(text)
    local x, y = string.match(tostring(text or ""), "(-?%d+)%D+(-?%d+)")
    if not x or not y then
        return nil
    end
    return { tonumber(x), tonumber(y) }
end

local function normalize_key(key)
    return string.lower(trim(key))
end

local function find_field_marker(lower, field_name, pos)
    local search_pos = pos
    while search_pos <= #lower do
        local s, e = string.find(lower, field_name .. "%s*:", search_pos)
        if not s then
            return nil, nil
        end
        if s == 1 then
            return s, e
        end
        local prev = string.sub(lower, s - 1, s - 1)
        if prev == "\n" or prev == "\t" then
            return s, e
        end
        search_pos = e + 1
    end
    return nil, nil
end

local function parse_gelab_fields(text)
    text = tostring(text or "")
    text = string.gsub(text, "\r", "")
    text = string.gsub(text, "<%s*[Tt][Hh][Ii][Nn][Kk]%s*>.-<%s*/%s*[Tt][Hh][Ii][Nn][Kk]%s*>", "")
    text = string.gsub(text, "<%s*/?%s*[Tt][Hh][Ii][Nn][Kk]%s*>", "")
    local lower = string.lower(text)
    local keys = { "verify", "note", "explain", "action_type", "action", "request_type", "assist_type", "point1", "point2", "point", "value", "text", "return", "summary", "key_process", "direction", "mode", "kind", "key", "tag", "duration", "seconds", "keyboard" }
    local markers = {}
    local pos = 1
    while pos <= #text do
        local best_key, best_s, best_e = nil, nil, nil
        for _, field_name in ipairs(keys) do
            local s, e = find_field_marker(lower, field_name, pos)
            if s and (not best_s or s < best_s) then
                best_key, best_s, best_e = field_name, s, e
            end
        end
        if not best_s then
            break
        end
        markers[#markers + 1] = { key = best_key, s = best_s, e = best_e }
        pos = best_e + 1
    end
    local out = {}
    for i, marker in ipairs(markers) do
        local value_start = marker.e + 1
        local value_end = #text
        if markers[i + 1] then
            value_end = markers[i + 1].s - 1
        end
        out[normalize_key(marker.key)] = trim(string.sub(text, value_start, value_end))
    end
    return out
end

local function parse_gelab_action(text)
    local fields = parse_gelab_fields(text)
    local action_type = fields.action or fields.action_type
    if not action_type or action_type == "" then
        return nil
    end
    local action = {
        action = action_type,
        verify = fields.verify,
        note = fields.note,
        explain = fields.explain,
        summary = fields.summary,
        key_process = fields.key_process,
        value = fields.value or fields.text,
        request_type = fields.request_type or fields.assist_type or fields.mode or fields.kind,
        ["return"] = fields["return"],
        direction = fields.direction,
        key = fields.key,
        tag = fields.tag,
        duration = fields.duration,
        seconds = fields.seconds,
        keyboard = fields.keyboard,
    }
    if fields.point then
        action.point = parse_point_text(fields.point)
    end
    if fields.point1 then
        action.point1 = parse_point_text(fields.point1)
    end
    if fields.point2 then
        action.point2 = parse_point_text(fields.point2)
    end
    return action
end

local function extract_json_object(text)
    text = tostring(text or "")
    local start_idx = string.find(text, "{", 1, true)
    local end_idx = string.match(text, "^.*()}")
    if not start_idx or not end_idx or end_idx < start_idx then
        return nil
    end
    return string.sub(text, start_idx, end_idx)
end

function M.parse_action(model_text)
    local action, err = json.decode(model_text or "")
    if action then
        return action, nil
    end
    local extracted = extract_json_object(model_text)
    if extracted then
        action, err = json.decode(extracted)
        if action then
            return action, nil
        end
        local quote_normalized = string.gsub(extracted, "'", "\"")
        action, err = json.decode(quote_normalized)
        if action then
            return action, nil
        end
    end
    local quote_normalized = string.gsub(tostring(model_text or ""), "'", "\"")
    action, err = json.decode(quote_normalized)
    if action then
        return action, nil
    end
    action = parse_gelab_action(model_text)
    if action then
        return action, nil
    end
    return nil, "decode action: " .. tostring(err) .. " content=" .. tostring(model_text)
end

function M.field(action, ...)
    if type(action) ~= "table" then
        return nil
    end
    for i = 1, select("#", ...) do
        local field_name = select(i, ...)
        local value = action[field_name]
        if value ~= nil then
            return value
        end
    end
    return nil
end

function M.first_non_empty_field(action, ...)
    for i = 1, select("#", ...) do
        local field_name = select(i, ...)
        local value = M.field(action, field_name)
        if value ~= nil then
            local text = trim(value)
            if text ~= "" then
                return text
            end
        end
    end
    return nil
end

function M.normalize_action_type(value)
    local action_type = string.upper(tostring(value or ""))
    if action_type == "SWIPE" then
        return "SLIDE"
    elseif action_type == "LONG_PRESS" then
        return "LONGPRESS"
    elseif action_type == "LONG_PRESS_DRAG" or action_type == "LONGPRESSANDDRAG" then
        return "LONGPRESS_DRAG"
    elseif action_type == "INPUT_TEXT" then
        return "TYPE"
    elseif action_type == "OPEN" or action_type == "LAUNCH" or action_type == "RUN_APP" or action_type == "OPEN_APP" then
        return "AWAKE"
    elseif action_type == "DOUBLE_TAP" or action_type == "DOUBLE_CLICK" then
        return "DOUBLECLICK"
    elseif action_type == "HOT_KEY" then
        return "HOTKEY"
    elseif action_type == "CALL_USER" then
        return "INFO"
    end
    return action_type
end

function M.point_value(point)
    if type(point) ~= "table" then
        return nil, nil
    end
    return tonumber(point[1]) or tonumber(point.x), tonumber(point[2]) or tonumber(point.y)
end

local function has_point(point)
    local x, y = M.point_value(point)
    return x ~= nil and y ~= nil
end

function M.action_value(action)
    return M.field(action, "value", "Value", "text", "Text")
end

function M.validate_action(action)
    if type(action) ~= "table" then
        return false, "action is not table"
    end
    local action_type = M.normalize_action_type(M.field(action, "action", "Action", "action_type", "type"))
    if action_type == "" then
        return false, "missing action"
    end
    if action_type == "CLICK" or action_type == "LONGPRESS" or action_type == "DOUBLECLICK" then
        if not has_point(M.field(action, "point", "Point")) then
            return false, action_type .. " missing point"
        end
    elseif action_type == "SLIDE" or action_type == "LONGPRESS_DRAG" then
        if not has_point(M.field(action, "point1", "Point1")) or not has_point(M.field(action, "point2", "Point2")) then
            return false, action_type .. " missing point1/point2"
        end
    elseif action_type == "SCROLL" then
        local direction = string.lower(tostring(M.field(action, "direction", "Direction") or ""))
        if direction ~= "" and direction ~= "up" and direction ~= "down" and direction ~= "left" and direction ~= "right" then
            return false, "invalid scroll direction"
        end
    elseif action_type == "TYPE" or action_type == "AWAKE" then
        local value = M.action_value(action)
        if type(value) ~= "string" or value == "" then
            return false, action_type .. " missing value"
        end
    elseif action_type == "HOTKEY" then
        local key_name = M.field(action, "key", "Key", "value", "Value")
        if type(key_name) ~= "string" or key_name == "" then
            return false, "HOTKEY missing key"
        end
    elseif action_type == "INFO" then
        local value = M.first_non_empty_field(action, "value", "Value", "text", "Text", "prompt", "Prompt", "explain", "Explain", "summary", "Summary")
        if not value then
            return false, "INFO missing value"
        end
        return true, nil
    elseif action_type == "WAIT" or action_type == "BACK" or action_type == "HOME" or action_type == "ENTER" or action_type == "COMPLETE" or action_type == "ABORT" then
        return true, nil
    else
        return false, "unsupported action: " .. action_type
    end
    return true, nil
end

local function repair_action_format(config, call_text_model, model_text, reason)
    local prompt = [[
你需要把下面的 GUI Agent 输出修复成脚本可解析的动作格式。不要执行任务，不要补充解释，只输出修复后的动作字段。

要求：
1. 必须保留一个动作，动作只能是 CLICK、TYPE、COMPLETE、WAIT、AWAKE、INFO、ABORT、SLIDE、SCROLL、LONGPRESS、DOUBLECLICK、LONGPRESS_DRAG、BACK、HOME、ENTER、HOTKEY。
2. 坐标仍然使用 0-1000 的屏幕坐标。
3. 输出格式为一行或多行 key:value 字段，至少包含 action。
4. INFO 必须包含具体 value；如果原输出没有足够参数，请把 action 改成 INFO，并在 value 中说明需要人工确认。

解析失败原因：
]] .. tostring(reason or "unknown") .. [[

原始输出：
]] .. tostring(model_text or "")
    return call_text_model(prompt, math.min(config.max_tokens, 1024))
end

function M.parse_action_checked(config, call_text_model, model_text)
    local action, err = M.parse_action(model_text)
    if action then
        local ok, validate_err = M.validate_action(action)
        if ok then
            return action, nil, nil
        end
        err = validate_err
    end

    local repaired_text = nil
    for _ = 1, config.format_repair_retry_count do
        local repair, repair_err = repair_action_format(config, call_text_model, model_text, err)
        if not repair then
            return nil, tostring(err) .. "; repair failed: " .. tostring(repair_err), repaired_text
        end
        repaired_text = repair
        action, err = M.parse_action(repair)
        if action then
            local ok, validate_err = M.validate_action(action)
            if ok then
                return action, nil, repaired_text
            end
            err = validate_err
        end
        model_text = repair
    end
    return nil, tostring(err), repaired_text
end

return M
