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

local CONFIG = {
    model_url = cfg["模型接口 URL"],
    api_key = cfg["API Key"],
    model = cfg["模型名称"],
    task = cfg["任务内容"],
    max_steps = tonumber(cfg["最大步数"]) or 20,
    request_timeout = tonumber(cfg["请求超时时间（秒）"]) or 120,
    assist_timeout = tonumber(cfg["人工介入超时时间（秒）"]) or 300,
    image_quality =  0.55,
    delay_after_action_ms = tonumber(cfg["动作后延迟毫秒数"]) or 1200,
    log_dir = XXT_LOG_PATH .. "/gelab-xxt-device-agent",
}

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
    if type(args.model_url) == "string" and args.model_url ~= "" then
        CONFIG.model_url = args.model_url
    end
    if type(args.model) == "string" and args.model ~= "" then
        CONFIG.model = args.model
    end
    if tonumber(args.assist_timeout) then
        CONFIG.assist_timeout = tonumber(args.assist_timeout)
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

local function capture_image_data_url()
    local img = screen.image()
    local jpg = img:jpeg_data(CONFIG.image_quality)
    if img.destroy then
        img:destroy()
    end
    return "data:image/jpeg;base64," .. jpg:base64_encode()
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

输出格式必须是：
<THINK> 思考的内容 </THINK>
explain:解释	action:动作空间和对应参数	summary:执行完当前步骤后的新历史总结
当 action 为 INFO 时，必须输出具体 value。INFO 不是任务完成，脚本会等待用户远控完成；之后你需要结合新的屏幕截图继续执行。
]]
end

local function user_prompt(task, history)
    return "已知用户指令为：" .. task .. "\n指令结束\n\n已知已经执行过的历史动作如下：" .. (history or "暂无历史操作") .. "\n当前手机屏幕截图如下："
end

local function call_model(image_data_url, history)
    local payload = {
        model = CONFIG.model,
        temperature = 0.1,
        top_p = 0.95,
        max_tokens = 1024,
        messages = {
            {
                role = "user",
                content = {
                    { type = "text", text = system_prompt() },
                    { type = "text", text = user_prompt(CONFIG.task, history) },
                    { type = "image_url", image_url = { url = image_data_url } },
                    { type = "text", text = "在执行操作之前，请务必回顾历史操作记录和动作空间，先在 <THINK> 中思考，然后输出 explain/action/summary。" },
                },
            },
        },
    }
    local code, _, body = http.post{
        url = CONFIG.model_url,
        timeout = CONFIG.request_timeout,
        headers = {
            ["Authorization"] = "Bearer " .. CONFIG.api_key,
            ["Content-Type"] = "application/json",
        },
        json = payload,
    }
    code = tonumber(code) or -1
    if code < 200 or code >= 300 then
        return nil, "model HTTP " .. tostring(code) .. ": " .. tostring(body)
    end
    local decoded, decode_err = json.decode(body or "")
    if not decoded then
        return nil, "decode model response: " .. tostring(decode_err)
    end
    local choice = decoded.choices and decoded.choices[1]
    local message = choice and choice.message
    local content = message and message.content
    if type(content) ~= "string" or content == "" then
        return nil, "empty model content"
    end
    return content, nil
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
    local keys = { "explain", "action_type", "action", "request_type", "assist_type", "point1", "point2", "point", "value", "text", "return", "summary", "direction", "mode", "kind", "key" }
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
        explain = fields.explain,
        summary = fields.summary,
        value = fields.value or fields.text,
        request_type = fields.request_type or fields.assist_type or fields.mode or fields.kind,
        ["return"] = fields["return"],
        direction = fields.direction,
        key = fields.key,
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
    elseif action_type == "INPUT_TEXT" then
        return "TYPE"
    elseif action_type == "OPEN" or action_type == "LAUNCH" or action_type == "RUN_APP" or action_type == "OPEN_APP" then
        return "AWAKE"
    end
    return action_type
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

local function assist_history_text(execution)
    if type(execution) ~= "table" or execution.executed ~= "assist_control" then
        return nil
    end
    local question = tostring(execution.question or "人工远控")
    return "用户介入结果：问题「" .. question .. "」，用户已远程控制设备并确认完成。请根据新的屏幕截图继续执行。"
end

local function build_history(step, action, execution)
    local summary = field(action, "summary", "Summary")
    local assist_history = assist_history_text(execution)
    if summary and summary ~= "" and assist_history then
        return summary .. "\n" .. assist_history
    elseif assist_history then
        return assist_history
    elseif summary and summary ~= "" then
        return summary
    end
    return "step " .. tostring(step) .. " action=" .. tostring(field(action, "action", "Action", "action_type", "type")) .. " value=" .. tostring(field(action, "value", "Value", "text", "Text") or "")
end

local function execute_action(action, image_data_url)
    local width, height = screen.size()
    local action_type = normalize_action_type(field(action, "action", "Action", "action_type", "type"))
    if action_type == "CLICK" then
        local x, y = scale_point(field(action, "point", "Point"), width, height)
        touch.tap(x, y, 40, 300)
        return false, { executed = "tap", x = x, y = y }
    elseif action_type == "LONGPRESS" then
        local x, y = scale_point(field(action, "point", "Point"), width, height)
        touch.on(x, y):msleep(1200):off()
        return false, { executed = "long_press", x = x, y = y }
    elseif action_type == "SLIDE" then
        local x0, y0 = scale_point(field(action, "point1", "Point1"), width, height)
        local x1, y1 = scale_point(field(action, "point2", "Point2"), width, height)
        swipe_pixels(x0, y0, x1, y1, 900)
        return false, { executed = "slide", x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
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
    sys.mkdir_p(CONFIG.log_dir)
    file.writes(CONFIG.log_dir .. "/session.jsonl", "")
    append_log({ time = now_ms(), type = "session_start", task = CONFIG.task, model_url = CONFIG.model_url, model = CONFIG.model })
    sys.toast("Device Agent start: " .. CONFIG.task)

    local history = "暂无历史操作"
    for step = 1, CONFIG.max_steps do
        local image_data_url = capture_image_data_url()
        local model_text, model_err = call_model(image_data_url, history)
        if model_err then
            append_log({ time = now_ms(), type = "error", step = step, error = model_err })
            sys.toast("Model error")
            return false, model_err
        end
        local action, parse_err = parse_action(model_text)
        if parse_err then
            append_log({ time = now_ms(), type = "error", step = step, model_response = model_text, error = parse_err })
            sys.toast("Parse error")
            return false, parse_err
        end
        local should_stop, execution = execute_action(action, image_data_url)
        append_log({
            time = now_ms(),
            type = "step",
            step = step,
            action = action,
            model_response = model_text,
            execution = execution,
        })
        history = build_history(step, action, execution)
        if should_stop then
            sys.toast(tostring(execution.message or execution.error or execution.reason or "Stopped"))
            return not execution.error, execution
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
