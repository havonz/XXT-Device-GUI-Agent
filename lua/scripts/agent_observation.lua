local M = {}
local UiElement = nil
local ui_element_loaded = false

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
    if value == "" then
        return nil
    end
    return value
end

local function traits_text(item)
    local traits = item and (item.traitsDescription or item.traits or item.traits_description)
    if type(traits) == "table" then
        local parts = {}
        for _, trait in ipairs(traits) do
            if trait ~= nil then
                parts[#parts + 1] = tostring(trait)
            end
        end
        return table.concat(parts, " ")
    end
    return tostring(traits or "")
end

local function has_trait(item, name)
    return string.find(traits_text(item), name, 1, true) ~= nil
end

local function element_role(item)
    if type(item.role) == "string" and item.role ~= "" then
        return item.role
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

local function is_single_ascii_key(text)
    text = tostring(text or "")
    if #text ~= 1 then
        return false
    end
    local byte = string.byte(text, 1)
    return byte >= 32 and byte <= 126
end

local function should_keep(item)
    local text = string_value(item.text or item.title or item.label)
    local value = string_value(item.value)
    local identifier = string_value(item.identifier)
    if item.hasTextEntry then
        return true
    end
    if item.isKeyboardKey and is_single_ascii_key(text) and not value and not identifier then
        return false
    end
    return text ~= nil or value ~= nil or identifier ~= nil
end

local function frame_value(item)
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

local function center_point(item, frame)
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
    local frame = frame_value(item)
    local center = center_point(item, frame)
    local slim = {
        id = index,
        text = string_value(item.text or item.title or item.label),
        value = string_value(item.value),
        role = element_role(item),
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
    if string_value(item.identifier) then
        slim.identifier = string_value(item.identifier)
    end
    return slim
end

local function compact_elements(elements, max_elements, width, height)
    local result = {}
    local source_count = type(elements) == "table" and #elements or 0
    for i = 1, source_count do
        local item = elements[i]
        if type(item) == "table" and should_keep(item) then
            result[#result + 1] = slim_element(item, #result + 1, width, height)
            if #result >= max_elements then
                break
            end
        end
    end
    return result, source_count
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

    local width, height = screen.size()
    local slim, source_count = compact_elements(elements, config.ui_element_observation_max_elements, width, height)
    local payload = {
        coordinate = "all point/box coordinates are 0-1000 action coordinates",
        count = #slim,
        source_count = source_count,
        truncated = source_count > #slim,
        elements = slim,
    }
    local text = json.encode(payload) or "{}"
    text = limit_text(text, config.ui_element_observation_max_chars)
    return {
        json = text,
        count = #slim,
        source_count = source_count,
        truncated = source_count > #slim or #text >= config.ui_element_observation_max_chars,
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
        truncated = observation.truncated,
        elapsed_ms = observation.elapsed_ms,
        error = observation.error,
    }
end

return M
