-- Device-side GELab-style GUI Agent for XXTouch.

local LCC = require("XXTLanControl")

while not LCC.connect() do
    sys.msleep(1000)
end

local cfg = LCC.get_ui_config()

if cfg["任务内容"] == nil or cfg["任务内容"] == "" then
    LCC.log(1, "请在运行前配置任务内容")
    return os.exit()
end

if cfg["模型接口 URL"] == nil or cfg["模型接口 URL"] == "" then
    LCC.log(1, "请在运行前配置模型接口 URL")
    return os.exit()
end

if cfg["模型名称"] == nil or cfg["模型名称"] == "" then
    LCC.log(1, "请在运行前配置模型名称")
    return os.exit()
end

LCC.log(1, "开始执行："..cfg["任务内容"])

local function cfg_number(key, default_value)
    local value = tonumber(cfg[key])
    if value == nil then
        return default_value
    end
    return value
end

local function cfg_enabled(key, default_value)
    local value = cfg[key]
    if value == nil or value == "" then
        return default_value
    end
    value = tostring(value)
    return value == "开启" or value == "是" or value == "true" or value == "1"
end

local function make_session_id()
    return os.date("%Y%m%d-%H%M%S") .. "-" .. tostring(math.random(100000, 999999))
end

math.randomseed(os.time())

local CONFIG = {
    model_url = cfg["模型接口 URL"],
    api_key = cfg["API Key"],
    model = cfg["模型名称"],
    task = cfg["任务内容"],
    temperature = cfg_number("模型温度", 0.1),
    max_tokens = cfg_number("单次响应最大 Token", 2048),
    max_steps = cfg_number("最大步数", 20),
    request_timeout = cfg_number("请求超时时间（秒）", 120),
    assist_timeout = cfg_number("人工介入超时时间（秒）", 300),
    image_quality = cfg_number("截图 JPEG 质量", 55) / 100,
    delay_after_action_ms = cfg_number("动作后延迟毫秒数", 1200),
    model_retry_count = cfg_number("模型请求重试次数", 2),
    format_repair_retry_count = cfg_number("动作格式修复次数", 1),
    recent_history_steps = cfg_number("最近历史保留步数", 8),
    enable_state_compression = cfg_enabled("启用历史压缩", true),
    state_compression_interval = cfg_number("历史压缩间隔步数", 10),
    state_compression_recent_window = cfg_number("压缩保留最近步数", 6),
    state_compression_max_chars = cfg_number("压缩状态最大字符数", 3000),
    save_screenshots = cfg_enabled("保存每步截图", false),
    click_loop_threshold = 3,
    slide_loop_threshold = 5,
    same_action_loop_threshold = 4,
    session_id = make_session_id(),
    log_root = XXT_LOG_PATH .. "/gelab-xxt-device-agent",
}

CONFIG.log_dir = CONFIG.log_root .. "/" .. CONFIG.session_id
CONFIG.screenshot_dir = CONFIG.log_dir .. "/screens"

local function normalize_config()
    if CONFIG.image_quality <= 0 or CONFIG.image_quality > 1 then
        CONFIG.image_quality = 0.55
    end
    if CONFIG.max_steps < 1 then
        CONFIG.max_steps = 1
    end
    if CONFIG.max_tokens < 256 then
        CONFIG.max_tokens = 256
    end
    if CONFIG.model_retry_count < 0 then
        CONFIG.model_retry_count = 0
    end
    if CONFIG.format_repair_retry_count < 0 then
        CONFIG.format_repair_retry_count = 0
    end
    if CONFIG.recent_history_steps < 1 then
        CONFIG.recent_history_steps = 1
    end
    if CONFIG.state_compression_interval < 1 then
        CONFIG.state_compression_interval = 10
    end
    if CONFIG.state_compression_recent_window < 1 then
        CONFIG.state_compression_recent_window = 6
    end
    if CONFIG.state_compression_max_chars < 500 then
        CONFIG.state_compression_max_chars = 500
    end
end

normalize_config()

local function merge_launch_args()
    if not utils or not utils.launch_args then
        return
    end
    local args = utils.launch_args()
    if type(args) ~= "table" then
        return
    end
    if type(args.task) == "string" and args.task ~= "" then
        CONFIG.task = args.task
    end
    if tonumber(args.max_steps) then
        CONFIG.max_steps = tonumber(args.max_steps)
    end
    if tonumber(args.temperature) then
        CONFIG.temperature = tonumber(args.temperature)
    end
    if tonumber(args.max_tokens) then
        CONFIG.max_tokens = tonumber(args.max_tokens)
    end
    if type(args.model_url) == "string" and args.model_url ~= "" then
        CONFIG.model_url = args.model_url
    end
    if type(args.model) == "string" and args.model ~= "" then
        CONFIG.model = args.model
    end
    if tonumber(args.assist_timeout) then
        CONFIG.assist_timeout = tonumber(args.assist_timeout)
    end
    if tonumber(args.recent_history_steps) then
        CONFIG.recent_history_steps = tonumber(args.recent_history_steps)
    end
    if args.enable_state_compression ~= nil then
        CONFIG.enable_state_compression = not not args.enable_state_compression
    end
end

local function now_ms()
    return math.floor(os.time() * 1000)
end

local function append_log(record)
    sys.mkdir_p(CONFIG.log_dir)
    local line = json.encode(record) or "{}"
    file.appends(CONFIG.log_dir .. "/session.jsonl", line .. "\n")
end

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

local function capture_image_data_url(step)
    local img = screen.image()
    local jpg = img:jpeg_data(CONFIG.image_quality)
    local screenshot_path = nil
    if CONFIG.save_screenshots and step then
        sys.mkdir_p(CONFIG.screenshot_dir)
        screenshot_path = CONFIG.screenshot_dir .. "/step_" .. tostring(step) .. ".jpg"
        file.writes(screenshot_path, jpg)
    end
    if img.destroy then
        img:destroy()
    end
    return "data:image/jpeg;base64," .. jpg:base64_encode(), screenshot_path
end

local function system_prompt()
    return [[
你是一个手机 GUI-Agent 操作专家，你需要根据用户下发的任务、手机屏幕截图和交互操作的历史记录，借助既定的动作空间与手机进行交互，从而完成用户的任务。
请牢记，手机屏幕坐标系以左上角为原点，x轴向右，y轴向下，取值范围均为 0-1000。

# 行动原则：
1. 你需要明确记录自己上一次的action，如果是滑动，不能超过5次。
2. 你需要严格遵循用户的指令，如果你和用户进行过对话，需要更遵守最后一轮的指令。
3. 在 iOS 设备上返回时，若页面上存在可见返回按钮，应该优先 CLICK 返回按钮；只有没有可见返回按钮时才使用 BACK。
4. 遇到无法决策的情况时，优先使用 INFO 请求用户提供必要的信息或远控协助，不要盲目猜测或冒险尝试可能错误的操作。
5. 不能输入任何手机号码、电话号码、身份证号、短信验证码、邮件验证码。遇到以上情况，必须使用 INFO 请求用户远控协助。

# Action Space:
1. CLICK：点击手机屏幕坐标，需包含点击的坐标位置 point。例如：action:CLICK	point:x,y
2. TYPE：在当前输入框输入文字，需包含输入内容 value；如果键盘未弹起，应先 CLICK 输入框。例如：action:TYPE	value:输入内容
3. COMPLETE：任务完成后向用户报告结果，需包含报告内容 return。例如：action:COMPLETE	return:完成任务后向用户报告的内容
4. WAIT：等待指定时长，需包含等待时间 value（秒）。例如：action:WAIT	value:2
5. AWAKE：唤醒指定应用，需包含应用名称 value。例如：action:AWAKE	value:设置
6. INFO：请求中控端人工远控，必须包含具体说明 value，不能只写“需要用户补充信息”。遇到需要手机号或其它无法稳定自动处理的问题时，使用 INFO 让用户远控解决当前屏幕后点击完成。例如：action:INFO	value:请远控完成当前验证后点击完成
7. ABORT：终止当前任务，需包含 value 说明原因。例如：action:ABORT	value:无法继续
8. SLIDE：在手机屏幕上滑动，需包含起点 point1 和终点 point2。例如：action:SLIDE	point1:x1,y1	point2:x2,y2
9. LONGPRESS：长按手机屏幕坐标，需包含 point。例如：action:LONGPRESS	point:x,y
10. BACK：返回上一页。
11. HOME：回到桌面。
12. ENTER：按回车/搜索/发送键。
13. DOUBLECLICK：双击屏幕坐标，需包含 point。例如：action:DOUBLECLICK	point:x,y
14. HOTKEY：按指定按键，需包含 key，支持 RETURN、BACKSPACE、VOLUMEUP、VOLUMEDOWN、SHOW_HIDE_KEYBOARD、LOCK。例如：action:HOTKEY	key:BACKSPACE
15. LONGPRESS_DRAG：长按后拖拽，需包含 point1 和 point2。例如：action:LONGPRESS_DRAG	point1:x1,y1	point2:x2,y2

输出格式必须是：
<THINK> 思考的内容 </THINK>
verify:上一步是否生效的判断	note:当前页面中和任务相关的事实	explain:解释	action:动作空间和对应参数	key_process:当前关键进展	summary:执行完当前步骤后的新历史总结
verify 必须明确说明上一步是否符合预期；note 要保留当前页面里和任务相关的文字与事实；key_process 要记录已完成和进行中的子任务。
当 action 为 INFO 时，必须输出具体 value。INFO 不是任务完成，脚本会等待用户远控完成；之后你需要结合新的屏幕截图继续执行。
]]
end

local function user_prompt(task, history)
    return "已知用户指令为：" .. task .. "\n指令结束\n\n已知已经执行过的历史动作如下：" .. (history or "暂无历史操作") .. "\n当前手机屏幕截图如下："
end

local function model_content_to_text(content)
    if type(content) == "string" then
        return content
    end
    if type(content) ~= "table" then
        return nil
    end
    local parts = {}
    for _, item in ipairs(content) do
        if type(item) == "table" and type(item.text) == "string" then
            parts[#parts + 1] = item.text
        elseif type(item) == "string" then
            parts[#parts + 1] = item
        end
    end
    if #parts == 0 then
        return nil
    end
    return table.concat(parts, "\n")
end

local function parse_model_body(body)
    local decoded, decode_err = json.decode(body or "")
    if not decoded then
        return nil, "decode model response: " .. tostring(decode_err)
    end
    local choice = decoded.choices and decoded.choices[1]
    local message = choice and choice.message
    local content = message and message.content
    local text = model_content_to_text(content)
    if type(text) ~= "string" or text == "" then
        return nil, "empty model content"
    end
    return text, nil
end

local function post_chat(payload, timeout_seconds)
    local last_err = nil
    local attempts = CONFIG.model_retry_count + 1
    for attempt = 1, attempts do
        local ok, code, _, body = pcall(function()
            return http.post{
                url = CONFIG.model_url,
                timeout = timeout_seconds or CONFIG.request_timeout,
                headers = {
                    ["Authorization"] = "Bearer " .. CONFIG.api_key,
                    ["Content-Type"] = "application/json",
                },
                json = payload,
            }
        end)
        if not ok then
            last_err = "model request failed: " .. tostring(code)
        else
            code = tonumber(code) or -1
            if code >= 200 and code < 300 then
                local content, parse_err = parse_model_body(body)
                if content then
                    return content, nil
                end
                last_err = parse_err
            else
                last_err = "model HTTP " .. tostring(code) .. ": " .. tostring(body)
            end
        end
        if attempt < attempts then
            sys.msleep(600 * attempt)
        end
    end
    return nil, last_err or "model request failed"
end

local function call_text_model(text, max_tokens)
    local payload = {
        model = CONFIG.model,
        temperature = 0.1,
        top_p = 0.95,
        max_tokens = max_tokens or CONFIG.max_tokens,
        messages = {
            {
                role = "user",
                content = {
                    { type = "text", text = text },
                },
            },
        },
    }
    return post_chat(payload, CONFIG.request_timeout)
end

local function call_model(image_data_url, history)
    local payload = {
        model = CONFIG.model,
        temperature = CONFIG.temperature,
        top_p = 0.95,
        max_tokens = CONFIG.max_tokens,
        messages = {
            {
                role = "user",
                content = {
                    { type = "text", text = system_prompt() },
                    { type = "text", text = user_prompt(CONFIG.task, history) },
                    { type = "image_url", image_url = { url = image_data_url } },
                    { type = "text", text = "在执行操作之前，请务必回顾历史操作记录和动作空间，先在 <THINK> 中思考，然后输出 verify/note/explain/action/key_process/summary。" },
                },
            },
        },
    }
    return post_chat(payload, CONFIG.request_timeout)
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
        for _, key in ipairs(keys) do
            local s, e = string.find(lower, key .. "%s*:", pos)
            if s and (not best_s or s < best_s) then
                best_key, best_s, best_e = key, s, e
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

local function parse_action(model_text)
    local action, err = json.decode(model_text)
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

local function swipe_pixels(x0, y0, x1, y1, duration_ms)
    duration_ms = duration_ms or 800
    local steps = 24
    local delay = math.floor(duration_ms / steps)
    touch.on(1, x0, y0)
    for i = 1, steps do
        local t = i / steps
        local x = math.floor(x0 + (x1 - x0) * t + 0.5)
        local y = math.floor(y0 + (y1 - y0) * t + 0.5)
        touch.move(1, x, y)
        sys.msleep(delay)
    end
    touch.off(1, x1, y1)
end

local function field(action, ...)
    for i = 1, select("#", ...) do
        local key = select(i, ...)
        local value = action[key]
        if value ~= nil then
            return value
        end
    end
    return nil
end

local function first_non_empty_field(action, ...)
    for i = 1, select("#", ...) do
        local key = select(i, ...)
        local value = action[key]
        if value ~= nil then
            local text = trim(value)
            if text ~= "" then
                return text
            end
        end
    end
    return nil
end

local function normalize_action_type(value)
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

local function point_value(point)
    if type(point) ~= "table" then
        return nil, nil
    end
    return tonumber(point[1]) or tonumber(point.x), tonumber(point[2]) or tonumber(point.y)
end

local function has_point(point)
    local x, y = point_value(point)
    return x ~= nil and y ~= nil
end

local function action_value(action)
    return field(action, "value", "Value", "text", "Text")
end

local function validate_action(action)
    if type(action) ~= "table" then
        return false, "action is not table"
    end
    local action_type = normalize_action_type(field(action, "action", "Action", "action_type", "type"))
    if action_type == "" then
        return false, "missing action"
    end
    if action_type == "CLICK" or action_type == "LONGPRESS" or action_type == "DOUBLECLICK" then
        if not has_point(field(action, "point", "Point")) then
            return false, action_type .. " missing point"
        end
    elseif action_type == "SLIDE" or action_type == "LONGPRESS_DRAG" then
        if not has_point(field(action, "point1", "Point1")) or not has_point(field(action, "point2", "Point2")) then
            return false, action_type .. " missing point1/point2"
        end
    elseif action_type == "SCROLL" then
        local direction = string.lower(tostring(field(action, "direction", "Direction") or ""))
        if direction ~= "" and direction ~= "up" and direction ~= "down" and direction ~= "left" and direction ~= "right" then
            return false, "invalid scroll direction"
        end
    elseif action_type == "TYPE" or action_type == "AWAKE" then
        local value = action_value(action)
        if type(value) ~= "string" or value == "" then
            return false, action_type .. " missing value"
        end
    elseif action_type == "HOTKEY" then
        local key_name = field(action, "key", "Key", "value", "Value")
        if type(key_name) ~= "string" or key_name == "" then
            return false, "HOTKEY missing key"
        end
    elseif action_type == "WAIT" or action_type == "BACK" or action_type == "HOME" or action_type == "ENTER" or action_type == "COMPLETE" or action_type == "INFO" or action_type == "ABORT" then
        return true, nil
    else
        return false, "unsupported action: " .. action_type
    end
    return true, nil
end

local function repair_action_format(model_text, reason)
    local prompt = [[
你需要把下面的 GUI Agent 输出修复成脚本可解析的动作格式。不要执行任务，不要补充解释，只输出修复后的动作字段。

要求：
1. 必须保留一个动作，动作只能是 CLICK、TYPE、COMPLETE、WAIT、AWAKE、INFO、ABORT、SLIDE、SCROLL、LONGPRESS、DOUBLECLICK、LONGPRESS_DRAG、BACK、HOME、ENTER、HOTKEY。
2. 坐标仍然使用 0-1000 的屏幕坐标。
3. 输出格式为一行或多行 key:value 字段，至少包含 action。
4. 如果原输出没有足够参数，请把 action 改成 INFO，并在 value 中说明需要人工确认。

解析失败原因：
]] .. tostring(reason or "unknown") .. [[

原始输出：
]] .. tostring(model_text or "")
    return call_text_model(prompt, math.min(CONFIG.max_tokens, 1024))
end

local function parse_action_checked(model_text)
    local action, err = parse_action(model_text)
    if action then
        local ok, validate_err = validate_action(action)
        if ok then
            return action, nil, nil
        end
        err = validate_err
    end

    local repaired_text = nil
    for _ = 1, CONFIG.format_repair_retry_count do
        local repair, repair_err = repair_action_format(model_text, err)
        if not repair then
            return nil, tostring(err) .. "; repair failed: " .. tostring(repair_err), repaired_text
        end
        repaired_text = repair
        action, err = parse_action(repair)
        if action then
            local ok, validate_err = validate_action(action)
            if ok then
                return action, nil, repaired_text
            end
            err = validate_err
        end
        model_text = repair
    end
    return nil, tostring(err), repaired_text
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
    return value
end

local function action_to_json(action)
    return json.encode(action or {}) or "{}"
end

local function record_to_history(record)
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

local function build_memory_history(memory)
    if type(memory) ~= "table" then
        return "暂无历史操作"
    end
    local parts = {}
    if type(memory.compressed_state) == "string" and memory.compressed_state ~= "" then
        parts[#parts + 1] = "以下是更早历史的压缩状态：\n" .. memory.compressed_state
    end

    local records = memory.records or {}
    local start_idx = #records - CONFIG.recent_history_steps + 1
    if start_idx < 1 then
        start_idx = 1
    end
    for i = start_idx, #records do
        parts[#parts + 1] = record_to_history(records[i])
    end
    if #parts == 0 then
        return "暂无历史操作"
    end
    return table.concat(parts, "\n\n")
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

local function compress_memory(memory)
    if not CONFIG.enable_state_compression or type(memory) ~= "table" then
        return nil
    end
    local records = memory.records or {}
    local compress_count = #records - CONFIG.state_compression_recent_window
    if compress_count <= 0 then
        return nil
    end

    local old_parts = {}
    for i = 1, compress_count do
        old_parts[#old_parts + 1] = record_to_history(records[i])
    end
    local prompt = [[
你是设备端 GUI Agent 的历史状态压缩器。请把较早步骤压缩成一段稳定状态，供后续动作决策使用。

要求：
1. 只输出压缩状态，不要预测下一步动作。
2. 必须保留用户任务、已完成进展、重要页面事实、用户介入结果、未解决风险、当前子目标。
3. 如果旧压缩状态与新增记录冲突，以新增记录为准。
4. 输出控制在 ]] .. tostring(CONFIG.state_compression_max_chars) .. [[ 字符以内。

旧压缩状态：
]] .. tostring(memory.compressed_state or "none") .. [[

新增较早步骤：
]] .. table.concat(old_parts, "\n\n")

    local compressed, err = call_text_model(prompt, math.min(CONFIG.max_tokens, 1200))
    if not compressed then
        return err
    end
    memory.compressed_state = limit_text(compressed, CONFIG.state_compression_max_chars)
    local kept = {}
    for i = compress_count + 1, #records do
        kept[#kept + 1] = records[i]
    end
    memory.records = kept
    return nil
end

local function point_signature(point)
    local x, y = point_value(point)
    if not x or not y then
        return "nil"
    end
    x = math.floor(x / 10 + 0.5) * 10
    y = math.floor(y / 10 + 0.5) * 10
    return tostring(x) .. "," .. tostring(y)
end

local function action_signature(action)
    local action_type = normalize_action_type(field(action, "action", "Action", "action_type", "type"))
    if action_type == "CLICK" or action_type == "LONGPRESS" or action_type == "DOUBLECLICK" then
        return action_type .. ":" .. point_signature(field(action, "point", "Point"))
    end
    if action_type == "SLIDE" or action_type == "LONGPRESS_DRAG" then
        return action_type .. ":" .. point_signature(field(action, "point1", "Point1")) .. ">" .. point_signature(field(action, "point2", "Point2"))
    end
    if action_type == "SCROLL" then
        return action_type .. ":" .. tostring(field(action, "direction", "Direction") or "down")
    end
    if action_type == "AWAKE" or action_type == "TYPE" or action_type == "WAIT" or action_type == "HOTKEY" then
        return action_type .. ":" .. tostring(action_value(action) or field(action, "key", "Key") or "")
    end
    return action_type
end

local function detect_repetition(memory, action)
    local records = (memory and memory.records) or {}
    local signature = action_signature(action)
    local action_type = normalize_action_type(field(action, "action", "Action", "action_type", "type"))
    local same_count = 1
    for i = #records, 1, -1 do
        local prev = records[i].action
        if action_signature(prev) ~= signature then
            break
        end
        same_count = same_count + 1
    end

    local threshold = CONFIG.same_action_loop_threshold
    if action_type == "CLICK" or action_type == "DOUBLECLICK" then
        threshold = CONFIG.click_loop_threshold
    elseif action_type == "SLIDE" or action_type == "SCROLL" then
        threshold = CONFIG.slide_loop_threshold
    end

    if same_count >= threshold then
        return "检测到连续重复动作 " .. signature .. " 已达到 " .. tostring(same_count) .. " 次。请远控确认当前页面状态，完成后点击完成。"
    end
    return nil
end

local function default_assist_question()
    return "请远程控制设备解决当前屏幕上的问题，完成后点击完成"
end

local function request_human_assist(action, image_data_url, width, height)
    if not LCC.assist then
        return true, { error = "XXTLanControl.assist unavailable", reason = "INFO" }
    end

    local raw_question = first_non_empty_field(action, "value", "Value", "text", "Text", "prompt", "Prompt", "explain", "Explain", "summary", "Summary")
    local question = raw_question or default_assist_question()
    local options = {
        title = "需要人工远控",
        text = question,
        timeout = CONFIG.assist_timeout,
        pollIntervalMs = 1000,
        input = {
            imageSrc = image_data_url,
            agent = "gelab-xxt-device-agent",
            task = CONFIG.task,
            action = "INFO",
            requestType = "control",
            screen = {
                width = width,
                height = height,
            },
        },
    }

    sys.toast("等待人工远控")
    local result, err, task = LCC.assist.request_control(options)

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

local function execute_action(action, image_data_url)
    local width, height = screen.size()
    local action_type = normalize_action_type(field(action, "action", "Action", "action_type", "type"))
    if action_type == "CLICK" then
        local x, y = scale_point(field(action, "point", "Point"), width, height)
        touch.tap(x, y, 40, 300)
        return false, { executed = "tap", x = x, y = y }
    elseif action_type == "DOUBLECLICK" then
        local x, y = scale_point(field(action, "point", "Point"), width, height)
        touch.tap(x, y, 40, 120)
        touch.tap(x, y, 40, 300)
        return false, { executed = "double_tap", x = x, y = y }
    elseif action_type == "LONGPRESS" then
        local x, y = scale_point(field(action, "point", "Point"), width, height)
        touch.on(x, y):msleep(1200):off()
        return false, { executed = "long_press", x = x, y = y }
    elseif action_type == "SLIDE" then
        local x0, y0 = scale_point(field(action, "point1", "Point1"), width, height)
        local x1, y1 = scale_point(field(action, "point2", "Point2"), width, height)
        swipe_pixels(x0, y0, x1, y1, 900)
        return false, { executed = "slide", x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
    elseif action_type == "LONGPRESS_DRAG" then
        local x0, y0 = scale_point(field(action, "point1", "Point1"), width, height)
        local x1, y1 = scale_point(field(action, "point2", "Point2"), width, height)
        touch.on(1, x0, y0)
        sys.msleep(900)
        local steps = 24
        for i = 1, steps do
            local t = i / steps
            local x = math.floor(x0 + (x1 - x0) * t + 0.5)
            local y = math.floor(y0 + (y1 - y0) * t + 0.5)
            touch.move(1, x, y)
            sys.msleep(45)
        end
        touch.off(1, x1, y1)
        return false, { executed = "long_press_drag", x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
    elseif action_type == "SCROLL" then
        local point = field(action, "point", "Point") or { 500, 500 }
        local x, y = scale_point(point, width, height)
        local dx = math.floor(width * 0.30)
        local dy = math.floor(height * 0.30)
        local direction = string.lower(tostring(field(action, "direction", "Direction") or "down"))
        local x1, y1 = x, y
        if direction == "down" then
            y1 = y - dy
        elseif direction == "up" then
            y1 = y + dy
        elseif direction == "left" then
            x1 = x - dx
        elseif direction == "right" then
            x1 = x + dx
        else
            return true, { error = "invalid scroll direction: " .. direction }
        end
        x1 = clamp(x1, 0, width - 1)
        y1 = clamp(y1, 0, height - 1)
        swipe_pixels(x, y, x1, y1, 900)
        return false, { executed = "scroll", direction = direction, x0 = x, y0 = y, x1 = x1, y1 = y1 }
    elseif action_type == "TYPE" then
        local point = field(action, "point", "Point")
        if point then
            local x, y = scale_point(point, width, height)
            touch.tap(x, y, 40, 500)
        end
        local text = tostring(field(action, "value", "Value", "text", "Text") or "")
        local ok = pcall(function()
            sys.input_text(text, false)
        end)
        if not ok and is_ascii(text) then
            pcall(function()
                key.send_text(text)
            end)
        end
        return false, { executed = "type", text = text, input_ok = ok }
    elseif action_type == "AWAKE" then
        local selected, candidates, err = resolve_app(field(action, "value", "Value", "app", "App"))
        if not selected then
            return true, { error = err, candidates = candidates }
        end
        local status = app.run(selected.bundle_id)
        return false, { executed = "awake", bundle_id = selected.bundle_id, name = selected.name, status = status }
    elseif action_type == "HOME" then
        key.press("HOMEBUTTON")
        return false, { executed = "home" }
    elseif action_type == "ENTER" then
        key.press("RETURN")
        return false, { executed = "enter" }
    elseif action_type == "HOTKEY" then
        local key_name = string.upper(tostring(field(action, "key", "Key", "value", "Value") or ""))
        local key_map = {
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
        local code = key_map[key_name]
        if not code then
            return true, { error = "unsupported hotkey: " .. key_name }
        end
        key.press(code)
        return false, { executed = "hotkey", key = code }
    elseif action_type == "BACK" then
        local y = math.floor(height / 2)
        swipe_pixels(3, y, math.floor(width * 0.35), y, 450)
        return false, { executed = "back" }
    elseif action_type == "WAIT" then
        local sec = tonumber(field(action, "value", "Value", "seconds", "Seconds")) or 2
        sec = clamp(sec, 0, 300)
        sys.msleep(math.floor(sec * 1000))
        return false, { executed = "wait", seconds = sec }
    elseif action_type == "COMPLETE" then
        return true, { done = true, reason = "COMPLETE", message = field(action, "return", "Return", "value", "Value") or "完成" }
    elseif action_type == "INFO" then
        return request_human_assist(action, image_data_url, width, height)
    elseif action_type == "ABORT" then
        return true, { done = true, reason = "ABORT", message = field(action, "value", "Value") or "无法继续" }
    end
    return true, { error = "unsupported action: " .. action_type }
end

local function run_agent()
    merge_launch_args()
    normalize_config()
    sys.mkdir_p(CONFIG.log_dir)
    file.writes(CONFIG.log_dir .. "/session.jsonl", "")
    append_log({
        time = now_ms(),
        type = "session_start",
        session_id = CONFIG.session_id,
        task = CONFIG.task,
        model_url = CONFIG.model_url,
        model = CONFIG.model,
        temperature = CONFIG.temperature,
        max_tokens = CONFIG.max_tokens,
        max_steps = CONFIG.max_steps,
        enable_state_compression = CONFIG.enable_state_compression,
    })
    sys.toast("Device Agent start: " .. CONFIG.task)

    local memory = {
        records = {},
        compressed_state = "",
    }
    for step = 1, CONFIG.max_steps do
        local image_data_url, screenshot_path = capture_image_data_url(step)
        local history = build_memory_history(memory)
        local model_text, model_err = call_model(image_data_url, history)
        if model_err then
            append_log({ time = now_ms(), type = "error", step = step, error = model_err })
            sys.toast("Model error")
            return false, model_err
        end
        local action, parse_err, repaired_text = parse_action_checked(model_text)
        if parse_err then
            append_log({ time = now_ms(), type = "error", step = step, model_response = model_text, repaired_response = repaired_text, error = parse_err })
            sys.toast("Parse error")
            return false, parse_err
        end

        local original_action = action
        local guard_reason = detect_repetition(memory, action)
        if guard_reason then
            action = {
                action = "INFO",
                value = guard_reason,
                verify = field(original_action, "verify", "Verify"),
                note = field(original_action, "note", "Note"),
                explain = "请求人工确认",
                key_process = field(original_action, "key_process", "Key_process") or "检测到重复动作，暂停自动执行",
                summary = "检测到重复动作，已转人工确认：" .. action_signature(original_action),
            }
            append_log({ time = now_ms(), type = "guard", step = step, reason = guard_reason, original_action = original_action })
        end

        local should_stop, execution = execute_action(action, image_data_url)
        local record = {
            step = step,
            action = action,
            execution = execution,
            screenshot = screenshot_path,
        }
        memory.records[#memory.records + 1] = record
        append_log({
            time = now_ms(),
            type = "step",
            step = step,
            action = action,
            original_action = original_action,
            model_response = model_text,
            repaired_response = repaired_text,
            screenshot = screenshot_path,
            execution = execution,
        })

        if should_stop then
            sys.toast(tostring(execution.message or execution.error or execution.reason or "Stopped"))
            return not execution.error, execution
        end

        if CONFIG.enable_state_compression and step % CONFIG.state_compression_interval == 0 then
            local compression_err = compress_memory(memory)
            append_log({
                time = now_ms(),
                type = compression_err and "compression_error" or "compression",
                step = step,
                error = compression_err,
                compressed_state = compression_err and nil or memory.compressed_state,
                recent_record_count = #memory.records,
            })
        end

        sys.msleep(CONFIG.delay_after_action_ms)
    end
    local message = "达到最大步数：" .. tostring(CONFIG.max_steps)
    append_log({ time = now_ms(), type = "stop", reason = "MAX_STEPS_REACHED", message = message })
    sys.toast(message)
    return false, message
end

local ok, result = run_agent()
return { ok = ok, result = result, log = CONFIG.log_dir .. "/session.jsonl" }
