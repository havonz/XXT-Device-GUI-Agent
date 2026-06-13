local Parser = require("agent_parser")
local Ui = require("agent_ui")
local UiElement = require("ui_element")

local M = {}

local function clamp(v, min_v, max_v)
    if v < min_v then
        return min_v
    end
    if v > max_v then
        return max_v
    end
    return v
end

local function scale_point(point, width, height)
    point = point or {}
    local x = tonumber(point[1]) or tonumber(point.x) or 0
    local y = tonumber(point[2]) or tonumber(point.y) or 0
    local px = math.floor(x / 1000 * (width - 1) + 0.5)
    local py = math.floor(y / 1000 * (height - 1) + 0.5)
    return clamp(px, 0, width - 1), clamp(py, 0, height - 1)
end

local function is_ascii(text)
    text = tostring(text or "")
    for i = 1, #text do
        if string.byte(text, i) > 127 then
            return false
        end
    end
    return true
end

local function norm(text)
    text = tostring(text or "")
    text = string.lower(text)
    text = string.gsub(text, "%s+", "")
    return text
end

local function trim_text(text)
    text = tostring(text or "")
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    return text
end

local function normalize_url(url)
    url = trim_text(url)
    if url == "" then
        return ""
    end
    if not string.find(url, "^[%w][%w+.-]*:") then
        url = "https://" .. url
    end
    return url
end

local function resolve_app(app_name)
    local target = norm(app_name)
    if target == "" then
        return nil, {}, "empty app name"
    end
    local exact, found = {}, {}
    for _, bid in ipairs(app.bundles()) do
        local localized = app.localized_name(bid) or bid
        local item = { bundle_id = bid, name = localized, source = "device" }
        if norm(localized) == target or norm(bid) == target then
            exact[#exact + 1] = item
        elseif string.find(norm(localized), target, 1, true) or string.find(norm(bid), target, 1, true) then
            found[#found + 1] = item
        end
    end
    local candidates = (#exact > 0) and exact or found
    if #candidates == 1 then
        return candidates[1], candidates, nil
    end
    if #candidates > 1 then
        return nil, candidates, "ambiguous app name"
    end
    return nil, candidates, "app not found"
end

function M.capture_image_data_url(config, step)
    local img = screen.image()
    local jpg = img:jpeg_data(config.image_quality)
    local screenshot_path = nil
    if config.save_screenshots and step then
        sys.mkdir_p(config.screenshot_dir)
        screenshot_path = config.screenshot_dir .. "/step_" .. tostring(step) .. ".jpg"
        file.writes(screenshot_path, jpg)
    end
    if img.destroy then
        img:destroy()
    end
    return "data:image/jpeg;base64," .. jpg:base64_encode(), screenshot_path
end

local function round_pixel(value)
    return math.floor(value + 0.5)
end

local function same_point(x1, y1, x2, y2)
    return math.abs(x1 - x2) <= 1 and math.abs(y1 - y2) <= 1
end

local function point_offset_clamped(x, y, ux, uy, offset, width, height)
    local px = round_pixel(x + ux * offset)
    local py = round_pixel(y + uy * offset)
    return clamp(px, 0, width - 1), clamp(py, 0, height - 1)
end

local function precise_swipe_overshoot(distance)
    if distance < 24 then
        return 0
    end
    return clamp(round_pixel(distance * 0.02), 6, 20)
end

local function move_finger_linear(finger, x0, y0, x1, y1, step_len, step_delay)
    step_len = step_len or 10
    step_delay = step_delay or 1
    local dx = x1 - x0
    local dy = y1 - y0
    local distance = math.sqrt(dx * dx + dy * dy)
    local steps = math.max(1, math.ceil(distance / step_len))
    for i = 1, steps do
        local t = i / steps
        local x = round_pixel(x0 + dx * t)
        local y = round_pixel(y0 + dy * t)
        touch.move(finger, x, y)
        if step_delay > 0 then
            sys.msleep(step_delay)
        end
    end
end

local function swipe_pixels(x0, y0, x1, y1, prevent_inertia)
    if prevent_inertia == nil then
        prevent_inertia = true
    end

    local width, height = screen.size()
    x0 = clamp(x0, 0, width - 1)
    y0 = clamp(y0, 0, height - 1)
    x1 = clamp(x1, 0, width - 1)
    y1 = clamp(y1, 0, height - 1)

    local dx = x1 - x0
    local dy = y1 - y0
    local distance = math.sqrt(dx * dx + dy * dy)
    if distance < 2 then
        touch.on(1, x0, y0)
        sys.msleep(80)
        touch.off(1, x0, y0)
        return
    end

    if not prevent_inertia then
        touch.on(1, x0, y0)
        move_finger_linear(1, x0, y0, x1, y1, 10, 1)
        sys.msleep(120)
        touch.off(1, x1, y1)
        return
    end

    local ux = dx / distance
    local uy = dy / distance
    local overshoot = precise_swipe_overshoot(distance)
    if overshoot == 0 then
        touch.on(1, x0, y0)
        move_finger_linear(1, x0, y0, x1, y1, 2, 8)
        sys.msleep(120)
        touch.off(1, x1, y1)
        return
    end

    local ox, oy = point_offset_clamped(x1, y1, ux, uy, overshoot, width, height)
    local blocked_by_edge = same_point(ox, oy, x1, y1)
    touch.on(1, x0, y0)
    move_finger_linear(1, x0, y0, ox, oy, 10, 1)

    if blocked_by_edge then
        local sx, sy = point_offset_clamped(x1, y1, -ux, -uy, math.min(overshoot, 24), width, height)
        if not same_point(sx, sy, x1, y1) then
            move_finger_linear(1, ox, oy, sx, sy, 1, 20)
            ox, oy = sx, sy
        end
    end

    move_finger_linear(1, ox, oy, x1, y1, 1, 20)
    sys.msleep(200)
    touch.off(1, x1, y1)
end

local function default_assist_question()
    return "请远程控制设备解决当前屏幕上的问题，完成后点击完成"
end

local function contains_any(text, words)
    for _, word in ipairs(words) do
        if string.find(text, word, 1, true) then
            return true
        end
    end
    return false
end

local function action_context(action)
    local parts = {}
    local field_names = {
        "value", "Value", "text", "Text", "note", "Note", "explain", "Explain",
        "summary", "Summary", "key_process", "Key_process", "return", "Return",
    }
    for _, field_name in ipairs(field_names) do
        local value = Parser.field(action, field_name)
        if value ~= nil then
            parts[#parts + 1] = tostring(value)
        end
    end
    local text = string.lower(table.concat(parts, " "))
    return string.gsub(text, "%s+", "")
end

local function digits_only(text)
    return string.gsub(tostring(text or ""), "%D", "")
end

local function compact_sensitive_text(text)
    text = string.lower(tostring(text or ""))
    return string.gsub(text, "[%s%-%+%(%)%.]", "")
end

local function is_short_code(text)
    local compact = compact_sensitive_text(text)
    local digits = digits_only(compact)
    if compact == digits and #digits >= 4 and #digits <= 8 then
        return true
    end
    local ascii = string.gsub(compact, "[^%w]", "")
    return ascii == compact and #ascii >= 4 and #ascii <= 10
end

local function sensitive_input_reason(action, text)
    local context = action_context(action)
    local compact = compact_sensitive_text(text)
    local digits = digits_only(text)
    if string.find(digits, "1[3-9]%d%d%d%d%d%d%d%d%d") then
        return "检测到模型试图输入疑似手机号。请人工确认当前输入是否允许，必要时远控完成。"
    end
    if string.find(compact, "%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d[%dx]") then
        return "检测到模型试图输入疑似身份证号。请人工确认当前输入是否允许，必要时远控完成。"
    end
    if contains_any(context, { "手机号", "手机号码", "电话号码", "电话", "phone", "mobile", "tel" }) and #digits >= 7 then
        return "检测到当前上下文可能要求输入电话号码。请人工确认并远控处理。"
    end
    if contains_any(context, { "身份证", "证件号", "证件号码", "idcard", "identity" }) and #digits >= 15 then
        return "检测到当前上下文可能要求输入身份证或证件号码。请人工确认并远控处理。"
    end
    if contains_any(context, { "验证码", "校验码", "动态码", "短信", "邮件验证码", "邮箱验证码", "otp", "verificationcode", "smscode", "emailcode" }) and is_short_code(text) then
        return "检测到当前上下文可能要求输入验证码。请人工确认并远控处理。"
    end
    return nil
end

local function request_human_assist(config, lcc, action, image_data_url, width, height)
    if not lcc.assist then
        return true, { error = "XXTLanControl.assist unavailable", reason = "INFO" }
    end

    local raw_question = Parser.first_non_empty_field(action, "value", "Value", "text", "Text", "prompt", "Prompt", "explain", "Explain", "summary", "Summary")
    local question = raw_question or default_assist_question()
    local options = {
        title = "需要人工远控",
        text = question,
        timeout = config.assist_timeout,
        pollIntervalMs = 1000,
        input = {
            imageSrc = image_data_url,
            agent = "gelab-xxt-device-agent",
            task = config.task,
            action = "INFO",
            requestType = "control",
            screen = {
                width = width,
                height = height,
            },
        },
    }

    Ui.toast("等待人工远控")
    local result, err, task = lcc.assist.request_control(options)

    if not result then
        return true, {
            error = "assist " .. tostring(err or "failed"),
            reason = "INFO",
            assist_type = "control",
            message = question,
            task = task,
        }
    end

    return false, {
        executed = "assist_control",
        assist_type = "control",
        question = question,
        completed = result.completed ~= false,
        result = result,
    }
end

local function ui_element_input_text(target, text)
    local ok, result, err = pcall(function()
        return UiElement.input_text(target, text)
    end)
    if not ok then
        return nil, tostring(result)
    end
    if result then
        return true, nil
    end
    return nil, tostring(err or "input failed")
end

local function try_ui_element_input(text, point, width, height)
    local result = {
        ui_input_attempted = true,
        ui_input_ok = false,
    }

    if point then
        local x, y = scale_point(point, width, height)
        result.x = x
        result.y = y

        local ok, input_err = ui_element_input_text({ x = x, y = y }, text)
        if ok then
            result.ui_input_ok = true
            result.input_method = "ui_element.input_text_at_point"
            return true, result
        else
            result.ui_input_error = input_err
        end

        touch.tap(x, y, 40, 500)
        return false, result
    end

    local ok, input_err = ui_element_input_text({
        role = "text_field",
        hittable = true,
    }, text)
    if ok then
        result.ui_input_ok = true
        result.input_method = "ui_element.input_text"
        return true, result
    end

    result.ui_input_error = input_err
    return false, result
end

local function try_key_send_text(text)
    local ok, err = pcall(function()
        key.send_text(text)
    end)
    if ok then
        return true, nil
    end
    return false, tostring(err)
end

local function try_sys_input_text(text)
    local ok, err = pcall(function()
        sys.input_text(text, false)
    end)
    if ok then
        return true, nil
    end
    return false, tostring(err)
end

local SCROLL_OFFSETS = {
    down = { dx = 0, dy = -1 },
    up = { dx = 0, dy = 1 },
    left = { dx = -1, dy = 0 },
    right = { dx = 1, dy = 0 },
}

local HOTKEY_CODES = {
    HOME = "HOMEBUTTON",
    HOMEBUTTON = "HOMEBUTTON",
    ENTER = "RETURN",
    RETURN = "RETURN",
    BACKSPACE = "BACKSPACE",
    DELETE = "BACKSPACE",
    VOLUMEUP = "VOLUMEUP",
    VOLUME_UP = "VOLUMEUP",
    VOLUMEDOWN = "VOLUMEDOWN",
    VOLUME_DOWN = "VOLUMEDOWN",
    KEYBOARD = "SHOW_HIDE_KEYBOARD",
    SHOW_HIDE_KEYBOARD = "SHOW_HIDE_KEYBOARD",
    POWER = "LOCK",
    LOCK = "LOCK",
}

local function unlock_screen_if_needed()
    if device.is_screen_locked() then
        device.unlock_screen()
        sys.msleep(500)
    end
end

local function handle_click(ctx, action)
    local x, y = scale_point(Parser.field(action, "point", "Point"), ctx.width, ctx.height)
    touch.tap(x, y, 40, 300)
    return false, { executed = "tap", x = x, y = y }
end

local function handle_doubleclick(ctx, action)
    local x, y = scale_point(Parser.field(action, "point", "Point"), ctx.width, ctx.height)
    touch.tap(x, y, 40, 120)
    touch.tap(x, y, 40, 300)
    return false, { executed = "double_tap", x = x, y = y }
end

local function handle_longpress(ctx, action)
    local x, y = scale_point(Parser.field(action, "point", "Point"), ctx.width, ctx.height)
    touch.on(x, y):msleep(1200):off()
    return false, { executed = "long_press", x = x, y = y }
end

local function handle_slide(ctx, action)
    local x0, y0 = scale_point(Parser.field(action, "point1", "Point1"), ctx.width, ctx.height)
    local x1, y1 = scale_point(Parser.field(action, "point2", "Point2"), ctx.width, ctx.height)
    swipe_pixels(x0, y0, x1, y1)
    return false, { executed = "slide", x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
end

local function handle_longpress_drag(ctx, action)
    local x0, y0 = scale_point(Parser.field(action, "point1", "Point1"), ctx.width, ctx.height)
    local x1, y1 = scale_point(Parser.field(action, "point2", "Point2"), ctx.width, ctx.height)
    touch.on(1, x0, y0)
    sys.msleep(900)
    move_finger_linear(1, x0, y0, x1, y1, 2, 12)
    sys.msleep(200)
    touch.off(1, x1, y1)
    return false, { executed = "long_press_drag", x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
end

local function handle_scroll(ctx, action)
    local point = Parser.field(action, "point", "Point") or { 500, 500 }
    local x, y = scale_point(point, ctx.width, ctx.height)
    local direction = string.lower(tostring(Parser.field(action, "direction", "Direction") or "down"))
    local offset = SCROLL_OFFSETS[direction]
    if not offset then
        return true, { error = "invalid scroll direction: " .. direction }
    end

    local dx = math.floor(ctx.width * 0.30)
    local dy = math.floor(ctx.height * 0.30)
    local x1 = clamp(x + offset.dx * dx, 0, ctx.width - 1)
    local y1 = clamp(y + offset.dy * dy, 0, ctx.height - 1)
    swipe_pixels(x, y, x1, y1)
    return false, { executed = "scroll", direction = direction, x0 = x, y0 = y, x1 = x1, y1 = y1 }
end

local function handle_type(ctx, action)
    local point = Parser.field(action, "point", "Point")
    local text = tostring(Parser.field(action, "value", "Value", "text", "Text") or "")
    local guard_reason = sensitive_input_reason(action, text)
    if guard_reason then
        return request_human_assist(ctx.config, ctx.lcc, {
            action = "INFO",
            value = guard_reason,
            note = Parser.field(action, "note", "Note"),
            explain = "安全拦截自动输入",
            summary = Parser.field(action, "summary", "Summary"),
        }, ctx.image_data_url, ctx.width, ctx.height)
    end

    local input_ok, execution = try_ui_element_input(text, point, ctx.width, ctx.height)
    execution.executed = "type"
    execution.text = text
    execution.input_ok = input_ok

    if not input_ok and is_ascii(text) then
        execution.key_input_attempted = true
        local key_ok, key_err = try_key_send_text(text)
        execution.key_input_ok = key_ok
        execution.key_input_error = key_err
        if key_ok then
            execution.input_ok = true
            execution.input_method = "key.send_text"
            return false, execution
        end
    end

    if not execution.input_ok then
        execution.sys_input_attempted = true
        local sys_ok, sys_err = try_sys_input_text(text)
        execution.sys_input_no_error = sys_ok
        execution.sys_input_error = sys_err
        execution.sys_input_unverified = sys_ok
        if sys_ok then
            execution.input_method = "sys.input_text"
        end
    end

    return false, execution
end

local function handle_awake(_, action)
    local selected, candidates, err = resolve_app(Parser.field(action, "value", "Value", "app", "App"))
    if not selected then
        return false, { error = err, candidates = candidates, recoverable = true, executed = "awake_failed" }
    end
    unlock_screen_if_needed()
    local status = app.run(selected.bundle_id)
    return false, { executed = "awake", bundle_id = selected.bundle_id, name = selected.name, status = status }
end

local function handle_openurl(_, action)
    local url = normalize_url(Parser.action_value(action))
    if url == "" then
        return false, { error = "empty url", recoverable = true, executed = "openurl_failed" }
    end
    unlock_screen_if_needed()
    local ok = app.open_url(url)
    return false, { executed = "openurl", url = url, ok = ok, error = ok and nil or "open_url failed", recoverable = not ok }
end

local function handle_home()
    key.press("HOMEBUTTON")
    return false, { executed = "home" }
end

local function handle_enter()
    key.press("RETURN")
    return false, { executed = "enter" }
end

local function handle_hotkey(_, action)
    local key_name = string.upper(tostring(Parser.field(action, "key", "Key", "value", "Value") or ""))
    local code = HOTKEY_CODES[key_name]
    if not code then
        return true, { error = "unsupported hotkey: " .. key_name }
    end
    key.press(code)
    return false, { executed = "hotkey", key = code }
end

local function handle_back(ctx)
    local y = math.floor(ctx.height / 2)
    swipe_pixels(3, y, math.floor(ctx.width * 0.35), y, false)
    return false, { executed = "back" }
end

local function handle_wait(_, action)
    local sec = tonumber(Parser.field(action, "value", "Value", "seconds", "Seconds")) or 2
    sec = clamp(sec, 0, 300)
    sys.msleep(math.floor(sec * 1000))
    return false, { executed = "wait", seconds = sec }
end

local function handle_complete(_, action)
    return true, { done = true, reason = "COMPLETE", message = Parser.field(action, "return", "Return", "value", "Value") or "完成" }
end

local function handle_info(ctx, action)
    return request_human_assist(ctx.config, ctx.lcc, action, ctx.image_data_url, ctx.width, ctx.height)
end

local function handle_abort(_, action)
    return true, { done = true, reason = "ABORT", message = Parser.field(action, "value", "Value") or "无法继续" }
end

local ACTION_HANDLERS = {
    CLICK = handle_click,
    DOUBLECLICK = handle_doubleclick,
    LONGPRESS = handle_longpress,
    SLIDE = handle_slide,
    LONGPRESS_DRAG = handle_longpress_drag,
    SCROLL = handle_scroll,
    TYPE = handle_type,
    AWAKE = handle_awake,
    OPENURL = handle_openurl,
    HOME = handle_home,
    ENTER = handle_enter,
    HOTKEY = handle_hotkey,
    BACK = handle_back,
    WAIT = handle_wait,
    COMPLETE = handle_complete,
    INFO = handle_info,
    ABORT = handle_abort,
}

function M.execute_action(config, lcc, action, image_data_url)
    local width, height = screen.size()
    local action_type = Parser.normalize_action_type(Parser.field(action, "action", "Action", "action_type", "type"))
    local handler = ACTION_HANDLERS[action_type]
    if not handler then
        return true, { error = "unsupported action: " .. action_type }
    end
    return handler({
        config = config,
        lcc = lcc,
        image_data_url = image_data_url,
        width = width,
        height = height,
    }, action)
end

return M
