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

local function normalize_key(field_name)
    return string.lower(trim(field_name))
end

local function has_strict_boundary(text, start_index)
    if start_index == 1 then
        return true
    end
    local index = start_index - 1
    while index >= 1 and string.sub(text, index, index) == " " do
        index = index - 1
    end
    local prev = string.sub(text, index, index)
    return prev == "\n" or prev == "\t"
end

local function has_space_boundary(text, start_index)
    if start_index == 1 then
        return true
    end
    local prev = string.sub(text, start_index - 1, start_index - 1)
    return prev == " " or prev == "\n" or prev == "\t"
end

local function find_field_marker(lower, field_name, pos, allow_space_boundary)
    local search_pos = pos
    while search_pos <= #lower do
        local s, e = string.find(lower, field_name .. "%s*:", search_pos)
        if not s then
            return nil, nil
        end
        local has_boundary = allow_space_boundary and has_space_boundary(lower, s) or has_strict_boundary(lower, s)
        if has_boundary then
            return s, e
        end
        search_pos = e + 1
    end
    return nil, nil
end

local function parse_fields(text, keys, allow_space_boundary)
    local lower = string.lower(text)
    local markers = {}
    local pos = 1
    while pos <= #text do
        local best_key, best_s, best_e = nil, nil, nil
        for _, field_name in ipairs(keys) do
            local s, e = find_field_marker(lower, field_name, pos, allow_space_boundary)
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

local function strip_think(text)
    text = tostring(text or "")
    text = string.gsub(text, "\r", "")
    text = string.gsub(text, "<%s*[Tt][Hh][Ii][Nn][Kk]%s*>.-<%s*/%s*[Tt][Hh][Ii][Nn][Kk]%s*>", "")
    text = string.gsub(text, "<%s*/?%s*[Tt][Hh][Ii][Nn][Kk]%s*>", "")
    return text
end

local function parse_gelab_fields(text)
    text = strip_think(text)
    local keys = { "verify", "note", "explain", "action_type", "action", "request_type", "assist_type", "point1", "point2", "point", "value", "text", "return", "summary", "key_process", "direction", "mode", "kind", "key", "tag", "duration", "seconds", "keyboard" }
    return parse_fields(text, keys, false)
end

local function add_key(keys, field_name)
    keys[#keys + 1] = field_name
end

local function first_token(text)
    return string.match(tostring(text or ""), "^%s*(%S+)") or ""
end

local function space_fallback_keys(action_type)
    action_type = string.upper(tostring(action_type or ""))
    local keys = { "action_type", "action" }
    if action_type == "CLICK" or action_type == "LONGPRESS" or action_type == "LONG_PRESS" or action_type == "DOUBLECLICK" or action_type == "DOUBLE_TAP" or action_type == "DOUBLE_CLICK" then
        add_key(keys, "point")
    elseif action_type == "SLIDE" or action_type == "SWIPE" or action_type == "LONGPRESS_DRAG" or action_type == "LONG_PRESS_DRAG" or action_type == "LONGPRESSANDDRAG" then
        add_key(keys, "point1")
        add_key(keys, "point2")
    elseif action_type == "TYPE" or action_type == "INPUT_TEXT" then
        add_key(keys, "value")
        add_key(keys, "text")
    elseif action_type == "AWAKE" or action_type == "OPEN" or action_type == "LAUNCH" or action_type == "RUN_APP" or action_type == "OPEN_APP" then
        add_key(keys, "value")
    elseif action_type == "WAIT" then
        add_key(keys, "value")
        add_key(keys, "seconds")
        add_key(keys, "duration")
    elseif action_type == "COMPLETE" then
        add_key(keys, "return")
        add_key(keys, "value")
    elseif action_type == "INFO" or action_type == "CALL_USER" or action_type == "ABORT" then
        add_key(keys, "value")
        add_key(keys, "text")
    elseif action_type == "HOTKEY" or action_type == "HOT_KEY" then
        add_key(keys, "key")
        add_key(keys, "value")
    elseif action_type == "SCROLL" then
        add_key(keys, "direction")
        add_key(keys, "point")
    end
    return keys
end

local function jsonish_key_pattern(field_name)
    return "[\"']" .. field_name .. "[\"']%s*:"
end

local function parse_jsonish_string_field(text, field_names)
    text = tostring(text or "")
    for _, field_name in ipairs(field_names) do
        local value = string.match(text, jsonish_key_pattern(field_name) .. "%s*[\"']([^\"']*)[\"']")
        if value then
            return value
        end
    end
    return nil
end

local function parse_jsonish_point_field(text, field_names)
    text = tostring(text or "")
    for _, field_name in ipairs(field_names) do
        local _, value_start = string.find(text, jsonish_key_pattern(field_name))
        if value_start then
            local value_text = string.sub(text, value_start + 1)
            local next_field = string.find(value_text, ",%s*[\"'][%w_]+[\"']%s*:")
            if next_field then
                value_text = string.sub(value_text, 1, next_field - 1)
            end
            local point = parse_point_text(value_text)
            if not point then
                point = parse_point_text(string.sub(text, value_start + 1, value_start + 120))
            end
            if point then
                return tostring(point[1]) .. "," .. tostring(point[2])
            end
        end
    end
    return nil
end

local function embedded_action_fields(raw_action)
    raw_action = trim(raw_action)
    if string.sub(raw_action, 1, 1) ~= "{" then
        return nil
    end

    local fields = {
        action = parse_jsonish_string_field(raw_action, { "action", "Action", "action_type", "type" }),
        point = parse_jsonish_point_field(raw_action, { "point", "Point" }),
        point1 = parse_jsonish_point_field(raw_action, { "point1", "Point1" }),
        point2 = parse_jsonish_point_field(raw_action, { "point2", "Point2" }),
        value = parse_jsonish_string_field(raw_action, { "value", "Value", "text", "Text" }),
        ["return"] = parse_jsonish_string_field(raw_action, { "return", "Return" }),
        direction = parse_jsonish_string_field(raw_action, { "direction", "Direction" }),
        key = parse_jsonish_string_field(raw_action, { "key", "Key" }),
        duration = parse_jsonish_string_field(raw_action, { "duration", "Duration" }),
        seconds = parse_jsonish_string_field(raw_action, { "seconds", "Seconds" }),
        keyboard = parse_jsonish_string_field(raw_action, { "keyboard", "Keyboard" }),
    }
    if not fields.action then
        return nil
    end
    return fields
end

local function merge_embedded_action_fields(fields)
    local embedded = embedded_action_fields(fields.action) or embedded_action_fields(fields.action_type)
    if not embedded then
        return fields
    end

    local merged = {}
    for key, value in pairs(fields) do
        merged[key] = value
    end
    for key, value in pairs(embedded) do
        if value ~= nil then
            merged[key] = value
        end
    end
    return merged
end

local function action_from_fields(fields)
    fields = merge_embedded_action_fields(fields)
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

local function parse_space_fallback_action(text)
    text = strip_think(text)
    local action_fields = parse_fields(text, { "action_type", "action" }, true)
    local action_type = first_token(action_fields.action or action_fields.action_type)
    if not action_type or action_type == "" then
        return nil
    end
    return action_from_fields(parse_fields(text, space_fallback_keys(action_type), true))
end

local function parse_gelab_action(text)
    local fields = parse_gelab_fields(text)
    local action = action_from_fields(fields)
    if action then
        local raw_action = fields.action or fields.action_type or ""
        if first_token(raw_action) ~= trim(raw_action) then
            local fallback_action = parse_space_fallback_action(text)
            if fallback_action then
                return fallback_action
            end
        end
        return action
    end
    return parse_space_fallback_action(text)
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

local function is_coordinate_action(action_type)
    action_type = M.normalize_action_type(action_type)
    return action_type == "CLICK"
        or action_type == "LONGPRESS"
        or action_type == "DOUBLECLICK"
        or action_type == "SLIDE"
        or action_type == "LONGPRESS_DRAG"
end

local function raw_has_point_field(text, field_name)
    text = strip_think(text)
    local fields = parse_fields(text, { field_name }, true)
    if fields[field_name] and parse_point_text(fields[field_name]) then
        return true
    end
    if string.find(text, '"' .. field_name .. '"%s*:%s*%[?%s*-?%d+%D+-?%d+') then
        return true
    end
    return string.find(text, "'" .. field_name .. "'%s*:%s*%[?%s*-?%d+%D+-?%d+") ~= nil
end

local function raw_has_required_coordinates(model_text, action_type)
    action_type = M.normalize_action_type(action_type)
    if action_type == "CLICK" or action_type == "LONGPRESS" or action_type == "DOUBLECLICK" then
        return raw_has_point_field(model_text, "point")
    end
    if action_type == "SLIDE" or action_type == "LONGPRESS_DRAG" then
        return raw_has_point_field(model_text, "point1") and raw_has_point_field(model_text, "point2")
    end
    return true
end

local function coordinate_missing_detail(model_text, action_type)
    action_type = M.normalize_action_type(action_type)
    if action_type == "SLIDE" or action_type == "LONGPRESS_DRAG" then
        local has_point1 = raw_has_point_field(model_text, "point1")
        local has_point2 = raw_has_point_field(model_text, "point2")
        if has_point1 and not has_point2 then
            return "missing point2; provided point1 only"
        end
        if not has_point1 and has_point2 then
            return "missing point1; provided point2 only"
        end
        return "missing point1 and point2"
    end
    if action_type == "CLICK" or action_type == "LONGPRESS" or action_type == "DOUBLECLICK" then
        return "missing point"
    end
    return "missing coordinates"
end

local function coordinate_missing_error(action_type, err, model_text)
    return "coordinate missing: " .. tostring(action_type) .. " " .. coordinate_missing_detail(model_text, action_type) .. "; " .. tostring(err or "missing point")
end

function M.action_value(action)
    return M.field(action, "value", "Value", "text", "Text")
end

function M.is_coordinate_missing_error(err)
    return string.find(tostring(err or ""), "^coordinate missing:", 1, false) ~= nil
end

function M.coordinate_missing_action_type(err)
    return string.match(tostring(err or ""), "^coordinate missing:%s*(%S+)")
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
5. 不允许凭空补充坐标。CLICK、LONGPRESS、DOUBLECLICK 必须只使用原始输出里已经存在的 point；SLIDE、LONGPRESS_DRAG 必须只使用原始输出里已经存在的 point1 和 point2。

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
        local action_type = M.normalize_action_type(M.field(action, "action", "Action", "action_type", "type"))
        if is_coordinate_action(action_type) and not raw_has_required_coordinates(model_text, action_type) then
            return nil, coordinate_missing_error(action_type, err, model_text), nil
        end
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
