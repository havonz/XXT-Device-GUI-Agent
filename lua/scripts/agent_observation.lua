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

local function now_ms()
    if sys and sys.mtime then
        return sys.mtime()
    end
    return math.floor(os.time() * 1000)
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

    local started = now_ms()
    local ok, elements = pcall(function()
        return UiElement.list_text_elements({
            max_level = 2,
            max_elements = config.ui_element_observation_max_elements,
        })
    end)
    local elapsed = now_ms() - started
    if not ok then
        return nil
    end
    if not elements then
        return nil
    end

    local size_ok, width, height = pcall(function()
        return screen.size()
    end)
    if not size_ok then
        return nil
    end
    local compact_ok, slim, source_count, filtered_count, truncated = pcall(compact_elements, elements, config.ui_element_observation_max_elements, width, height)
    if not compact_ok then
        return nil
    end
    local payload = {
        coordinate = "all point/box coordinates are 0-1000 action coordinates",
        count = #slim,
        truncated = truncated,
        elements = slim,
    }
    local encode_ok, text = pcall(function()
        return json.encode(payload)
    end)
    if not encode_ok or type(text) ~= "string" or text == "" then
        return nil
    end
    text = limit_text(text, config.ui_element_observation_max_chars)
    return {
        json = text,
        count = #slim,
        source_count = source_count,
        filtered_count = filtered_count,
        truncated = truncated or #text >= config.ui_element_observation_max_chars,
        elapsed_ms = elapsed,
    }
end

function M.to_prompt(observation)
    if type(observation) ~= "table" or type(observation.json) ~= "string" or observation.json == "" then
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
