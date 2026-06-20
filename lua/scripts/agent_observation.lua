local M = {}
local UiElement = nil
local ui_element_loaded = false

local GENERIC_TEXTS = {
    ["可调控制"] = true,
    ["调整控制"] = true,
    ["Page Control"] = true,
    ["page control"] = true,
}

local NOISY_TEXTS = {
    ["清除文本"] = true,
    ["Clear Text"] = true,
    ["图像"] = true,
    ["Image"] = true,
    ["image"] = true,
    ["chevron"] = true,
}

local IGNORED_ROLES = {
    keyboard_key = true,
    static_text = true,
    scrollable = true,
}

local TOGGLE_STATE_VALUES = {
    ["0"] = true,
    ["1"] = true,
}

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

local function string_value(value)
    if value == nil then
        return nil
    end
    value = tostring(value)
    value = string.gsub(value, "^%s+", "")
    value = string.gsub(value, "%s+$", "")
    if value == "" then
        return nil
    end
    return value
end

local function traits_text(item)
    if type(item) ~= "table" then
        return ""
    end
    local traits = item and (item.traitsDescription or item.traits or item.traits_description)
    if type(traits) == "table" then
        local parts = {}
        for _, trait in pairs(traits) do
            if type(trait) == "string" and trait ~= "" then
                parts[#parts + 1] = trait
            end
        end
        return table.concat(parts, " ")
    end
    if type(traits) == "string" then
        return traits
    end
    return ""
end

local function has_trait(item, name)
    return string.find(traits_text(item), name, 1, true) ~= nil
end

local function element_role(item)
    if type(item) ~= "table" then
        return nil
    end
    if type(item.role) == "string" and item.role ~= "" then
        return item.role
    end
    if item.isToggle or has_trait(item, "Toggle") then
        return "switch"
    end
    if has_trait(item, "LaunchIcon") then
        return "app_icon"
    end
    if item.hasTextEntry or has_trait(item, "TextEntry") then
        return "text_field"
    end
    if item.isKeyboardKey or has_trait(item, "KeyboardKey") then
        return "keyboard_key"
    end
    if has_trait(item, "Button") then
        return "button"
    end
    if has_trait(item, "StaticText") then
        return "static_text"
    end
    if has_trait(item, "Link") then
        return "link"
    end
    if has_trait(item, "Image") then
        return "image"
    end
    if has_trait(item, "Adjustable") then
        return "adjustable"
    end
    if has_trait(item, "Scrollable") then
        return "scrollable"
    end
    return nil
end

local function frame_value(item)
    if type(item) ~= "table" then
        return nil
    end
    local x = tonumber(item.x)
    local y = tonumber(item.y)
    local width = tonumber(item.width)
    local height = tonumber(item.height)
    if not x or not y or not width or not height then
        return nil
    end
    return {
        x = math.floor(x + 0.5),
        y = math.floor(y + 0.5),
        w = math.floor(width + 0.5),
        h = math.floor(height + 0.5),
    }
end

local function frame_is_usable(frame, screen_width, screen_height)
    if not frame or frame.w < 8 or frame.h < 8 then
        return false
    end
    local cx = frame.x + frame.w / 2
    local cy = frame.y + frame.h / 2
    return cx >= 0 and cx < screen_width and cy >= 0 and cy < screen_height
end

local function is_generic_text(text)
    return GENERIC_TEXTS[tostring(text or "")] == true
end

local function is_noisy_text(text)
    return NOISY_TEXTS[tostring(text or "")] == true
end

local function is_generic_identifier(identifier)
    identifier = tostring(identifier or "")
    if identifier == "" or identifier == "0" then
        return true
    end
    return string.find(identifier, "^%d+:%d+$") ~= nil
end

local function meaningful_value(item, role)
    if type(item) ~= "table" then
        return nil
    end
    local value = string_value(item.value)
    if not value then
        return nil
    end
    if role == "app_icon" then
        return nil
    end
    if item.isToggle and TOGGLE_STATE_VALUES[value] then
        return nil
    end
    return value
end

local function should_keep(item, frame, screen_width, screen_height)
    if type(item) ~= "table" then
        return false
    end
    if item.isVisible == false then
        return false
    end
    if not frame_is_usable(frame, screen_width, screen_height) then
        return false
    end

    local role = element_role(item)
    local text = string_value(item.text or item.title or item.label)
    local value = meaningful_value(item, role)
    if item.hasTextEntry then
        return true
    end
    if IGNORED_ROLES[role] then
        return false
    end
    if role == "adjustable" and is_generic_text(text) then
        return false
    end
    if is_noisy_text(text) then
        return false
    end
    return text ~= nil or value ~= nil
end

local function center_point(item, frame)
    if type(item) ~= "table" then
        return nil
    end
    local center = item.centerPoint or item.center or item.center_point
    local x = center and tonumber(center.x or center[1])
    local y = center and tonumber(center.y or center[2])
    if (not x or not y) and frame then
        x = frame.x + frame.w / 2
        y = frame.y + frame.h / 2
    end
    if not x or not y then
        return nil
    end
    return {
        x = math.floor(x + 0.5),
        y = math.floor(y + 0.5),
    }
end

local function action_point(center, width, height)
    if not center or width <= 1 or height <= 1 then
        return nil
    end
    return {
        x = math.floor(center.x / (width - 1) * 1000 + 0.5),
        y = math.floor(center.y / (height - 1) * 1000 + 0.5),
    }
end

local function action_box(frame, width, height)
    if not frame or width <= 1 or height <= 1 then
        return nil
    end
    local x1 = math.floor(frame.x / (width - 1) * 1000 + 0.5)
    local y1 = math.floor(frame.y / (height - 1) * 1000 + 0.5)
    local x2 = math.floor((frame.x + frame.w) / (width - 1) * 1000 + 0.5)
    local y2 = math.floor((frame.y + frame.h) / (height - 1) * 1000 + 0.5)
    return {
        x1 = math.max(0, math.min(1000, x1)),
        y1 = math.max(0, math.min(1000, y1)),
        x2 = math.max(0, math.min(1000, x2)),
        y2 = math.max(0, math.min(1000, y2)),
    }
end

local function point_in_box(x, y, box)
    return type(box) == "table"
        and x >= (tonumber(box.x1) or 0)
        and x <= (tonumber(box.x2) or 0)
        and y >= (tonumber(box.y1) or 0)
        and y <= (tonumber(box.y2) or 0)
end

local function box_area(box)
    if type(box) ~= "table" then
        return 1000000
    end
    return math.max(1, ((tonumber(box.x2) or 0) - (tonumber(box.x1) or 0)))
        * math.max(1, ((tonumber(box.y2) or 0) - (tonumber(box.y1) or 0)))
end

local function slim_element(item, index, width, height)
    if type(item) ~= "table" then
        return nil
    end
    local frame = frame_value(item)
    local center = center_point(item, frame)
    local role = element_role(item)
    local slim = {
        id = index,
        text = string_value(item.text or item.title or item.label),
        value = meaningful_value(item, role),
        role = role,
        point = action_point(center, width, height),
        box = action_box(frame, width, height),
    }
    if item.hasTextEntry ~= nil then
        slim.text_entry = item.hasTextEntry and true or nil
    end
    if item.isKeyboardKey ~= nil then
        slim.keyboard_key = item.isKeyboardKey and true or nil
    end
    if item.canHit ~= nil then
        slim.hittable = item.canHit and true or false
    end
    if item.selected ~= nil then
        slim.selected = item.selected and true or false
    end
    if item.checked ~= nil then
        slim.checked = item.checked and true or false
    end
    local identifier = string_value(item.identifier)
    if identifier and not is_generic_identifier(identifier) then
        slim.identifier = identifier
    end
    return slim
end

local function compact_elements(elements, max_elements, width, height)
    local result = {}
    local filtered_count = 0
    local truncated = false
    local source_count = type(elements) == "table" and #elements or 0
    for i = 1, source_count do
        local item = elements[i]
        local frame = type(item) == "table" and frame_value(item) or nil
        if type(item) == "table" and should_keep(item, frame, width, height) then
            if #result < max_elements then
                local slim = slim_element(item, #result + 1, width, height)
                if slim then
                    result[#result + 1] = slim
                else
                    filtered_count = filtered_count + 1
                end
            else
                truncated = true
            end
        else
            filtered_count = filtered_count + 1
        end
    end
    return result, source_count, filtered_count, truncated
end

function M.capture(config)
    if not config.enable_ui_element_observation then
        return nil
    end

    if not ui_element_loaded then
        local ok, module = pcall(require, "ui_element")
        ui_element_loaded = true
        if ok then
            UiElement = module
        end
    end
    if not UiElement then
        return nil
    end

    local started = sys.mtime()
    local ok, elements = pcall(function()
        return UiElement.list_text_elements({
            max_level = 2,
            max_elements = config.ui_element_observation_max_elements,
        })
    end)
    local elapsed = sys.mtime() - started
    if not ok then
        return nil
    end
    if not elements then
        return nil
    end

    local width, height = screen.size()
    local slim, source_count, filtered_count, truncated = compact_elements(elements, config.ui_element_observation_max_elements, width, height)
    local payload = {
        coordinate = "all point/box coordinates are 0-1000 action coordinates",
        count = #slim,
        truncated = truncated,
        elements = slim,
    }
    local text = json.encode(payload)
    if type(text) ~= "string" or text == "" then
        return nil
    end
    text = limit_text(text, config.ui_element_observation_max_chars)
    return {
        payload = payload,
        json = text,
        count = #slim,
        source_count = source_count,
        filtered_count = filtered_count,
        truncated = truncated or #text >= config.ui_element_observation_max_chars,
        elapsed_ms = elapsed,
    }
end

function M.text_at_point(observation, x, y)
    if type(observation) ~= "table" or type(observation.payload) ~= "table" or type(observation.payload.elements) ~= "table" then
        return nil
    end
    local best_text, best_area
    for _, element in ipairs(observation.payload.elements) do
        local text = string_value(element.text or element.value)
        if text and point_in_box(x, y, element.box) then
            local area = box_area(element.box)
            if not best_area or area < best_area then
                best_text = text
                best_area = area
            end
        end
    end
    return best_text
end

local element_point

local function element_text_value(element)
    if type(element) ~= "table" then
        return nil
    end
    return string_value(element.text or element.value)
end

function M.find_visible_text_target(observation, targets, options)
    if type(observation) ~= "table" or type(observation.payload) ~= "table" or type(observation.payload.elements) ~= "table" then
        return nil
    end
    if type(targets) ~= "table" or #targets == 0 then
        return nil
    end
    options = options or {}

    for target_index = #targets, 1, -1 do
        local target = string_value(targets[target_index])
        if target then
            for _, element in ipairs(observation.payload.elements) do
                local text = element_text_value(element)
                local point = element_point(element)
                if text == target and point and element.hittable ~= false then
                    local box = type(element.box) == "table" and element.box or nil
                    local y1 = box and tonumber(box.y1) or point[2]
                    local top_navigation_hit = y1 and y1 < 140
                    if not (
                        (options.skip_top_navigation and top_navigation_hit)
                        or (options.skip_first_top_title and target_index == 1 and top_navigation_hit)
                    ) then
                        return {
                            text = text,
                            point = { point[1], point[2] },
                            element = element,
                            target_index = target_index,
                        }
                    end
                end
            end
        end
    end
    return nil
end

local POINT_ACTION_TYPES = {
    CLICK = true,
    LONGPRESS = true,
    DOUBLECLICK = true,
}

local CLICK_COMMAND_WORDS = {
    CLICK = { "点击", "点按", "轻点", "点选", "选择", "打开", "进入", "按下" },
    DOUBLECLICK = { "双击", "点击", "点按", "轻点" },
    LONGPRESS = { "长按", "按住" },
}

local function field_value(action, ...)
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

local function normalize_action_type(value)
    value = string.upper(tostring(value or ""))
    if value == "LONG_PRESS" then
        return "LONGPRESS"
    end
    if value == "DOUBLE_TAP" or value == "DOUBLE_CLICK" then
        return "DOUBLECLICK"
    end
    return value
end

local function action_intent_text(action)
    local parts = {}
    for _, key in ipairs({ "value", "text", "note", "explain", "summary", "key_process" }) do
        local value = field_value(action, key, string.upper(string.sub(key, 1, 1)) .. string.sub(key, 2))
        if type(value) == "string" and value ~= "" then
            parts[#parts + 1] = value
        end
    end
    return table.concat(parts, " ")
end

local function model_intent_text(model_text)
    local parts = {}
    for line in string.gmatch(tostring(model_text or "") .. "\n", "([^\n]*)\n") do
        local key = string.match(line, "^%s*([%w_]+)%s*:")
        key = key and string.lower(key) or nil
        if key ~= "verify" and key ~= "execution_result" and key ~= "screen_after_action" then
            parts[#parts + 1] = line
        end
    end
    return table.concat(parts, "\n")
end

local function contains_quoted_text(context, target)
    return string.find(context, "“" .. target .. "”", 1, true) ~= nil
        or string.find(context, "\"" .. target .. "\"", 1, true) ~= nil
        or string.find(context, "'" .. target .. "'", 1, true) ~= nil
end

local SENTENCE_SEPARATORS = { "。", "；", "，", ",", ".", "!", "?", "！", "？", "\n" }

local function clip_to_sentence(text)
    local limit = #text
    for _, separator in ipairs(SENTENCE_SEPARATORS) do
        local index = string.find(text, separator, 1, true)
        if index and index - 1 < limit then
            limit = index - 1
        end
    end
    return string.sub(text, 1, limit)
end

local function contains_command_target(context, target, action_type)
    if context == "" or target == "" then
        return false
    end
    local words = CLICK_COMMAND_WORDS[action_type] or CLICK_COMMAND_WORDS.CLICK
    for _, word in ipairs(words) do
        local start_at = 1
        while start_at <= #context do
            local _, word_end = string.find(context, word, start_at, true)
            if not word_end then
                break
            end
            local nearby = clip_to_sentence(string.sub(context, word_end + 1, word_end + 180))
            if string.find(nearby, target, 1, true) then
                return true
            end
            start_at = word_end + 1
        end
    end
    return false
end

element_point = function(element)
    if type(element) ~= "table" then
        return nil
    end
    local point = element.point
    local x = type(point) == "table" and (tonumber(point.x) or tonumber(point[1])) or nil
    local y = type(point) == "table" and (tonumber(point.y) or tonumber(point[2])) or nil
    if (not x or not y) and type(element.box) == "table" then
        x = ((tonumber(element.box.x1) or 0) + (tonumber(element.box.x2) or 0)) / 2
        y = ((tonumber(element.box.y1) or 0) + (tonumber(element.box.y2) or 0)) / 2
    end
    if not x or not y then
        return nil
    end
    return {
        math.max(0, math.min(1000, math.floor(x + 0.5))),
        math.max(0, math.min(1000, math.floor(y + 0.5))),
    }
end

local function copy_action(action)
    local out = {}
    for key, value in pairs(action or {}) do
        out[key] = value
    end
    return out
end

local function target_score(element_text, action_context, model_context, action_type, action)
    local score = 0
    local value = field_value(action, "value", "Value", "text", "Text")
    if type(value) == "string" and string_value(value) == element_text then
        score = score + 220
    end
    if contains_command_target(action_context, element_text, action_type) then
        score = score + 180
    end
    if score == 0 and contains_command_target(model_context, element_text, action_type) then
        score = score + 120
    end
    if score > 0 and contains_quoted_text(action_context, element_text) then
        score = score + 20
    end
    if score > 0 then
        score = score + math.min(#element_text, 60)
    end
    return score
end

local function best_target_candidate(observation, action, model_text, action_type)
    if type(observation) ~= "table" or type(observation.payload) ~= "table" or type(observation.payload.elements) ~= "table" then
        return nil
    end

    local action_context = action_intent_text(action)
    local model_context = model_intent_text(model_text)
    local best, second
    for _, element in ipairs(observation.payload.elements) do
        local point = element_point(element)
        local texts = {}
        local element_text = string_value(element.text)
        local element_value = string_value(element.value)
        if element_text then
            texts[#texts + 1] = element_text
        end
        if element_value and element_value ~= element_text then
            texts[#texts + 1] = element_value
        end
        for _, text in ipairs(texts) do
            if point and text and #text >= 2 then
                local score = target_score(text, action_context, model_context, action_type, action)
                if element.hittable ~= false and score > 0 then
                    score = score + 5
                end
                if score > 0 then
                    local candidate = {
                        score = score,
                        text = text,
                        point = point,
                        element = element,
                    }
                    if not best or candidate.score > best.score then
                        second = best
                        best = candidate
                    elseif not second or candidate.score > second.score then
                        second = candidate
                    end
                end
            end
        end
    end
    return best, second
end

function M.autofill_point_action(observation, action, model_text, action_type)
    action_type = normalize_action_type(action_type or field_value(action, "action", "Action", "action_type", "type"))
    if not POINT_ACTION_TYPES[action_type] then
        return nil
    end
    if type(action) ~= "table" or element_point({ point = field_value(action, "point", "Point") }) then
        return nil
    end

    local best, second = best_target_candidate(observation, action, model_text, action_type)
    if not best or best.score < 100 or (second and second.score == best.score) then
        return nil
    end

    local filled = copy_action(action)
    filled.action = action_type
    filled.point = { best.point[1], best.point[2] }
    return filled, {
        target_text = best.text,
        point = { best.point[1], best.point[2] },
        element_id = best.element and best.element.id,
        score = best.score,
    }
end

function M.to_prompt(observation)
    if type(observation) ~= "table" or type(observation.json) ~= "string" or observation.json == "" then
        return nil
    end
    if tonumber(observation.count) == nil or tonumber(observation.count) <= 0 then
        return nil
    end
    return [[
当前结构化文本元素列表如下，只对应本次截图；任何动作执行、页面变化、滚动或输入后都立即过期。不要把完整 JSON 复制进 note、summary、key_process 或历史总结，只引用必要的元素文本、role 或 point。
注意：列表中的 point 和 box 已经转换为 0-1000 动作坐标；不要使用或推断物理像素坐标。
]] .. observation.json
end

function M.meta(observation)
    if type(observation) ~= "table" then
        return nil
    end
    return {
        enabled = true,
        count = observation.count,
        source_count = observation.source_count,
        filtered_count = observation.filtered_count,
        truncated = observation.truncated,
        elapsed_ms = observation.elapsed_ms,
        error = observation.error,
    }
end

return M
