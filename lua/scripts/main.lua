-- Device-side GELab-style GUI Agent for XXTouch.

local LCC = require("XXTLanControl")
local Config = require("agent_config")
local Executor = require("agent_executor")
local Memory = require("agent_memory")
local Model = require("agent_model")
local Parser = require("agent_parser")
local Ui = require("agent_ui")

while not LCC.connect() do
    sys.msleep(1000)
end

local cfg = LCC.get_ui_config() or {}
local CONFIG = Config.from_ui(cfg)

Config.merge_launch_args(CONFIG)
Config.normalize(CONFIG)

local function notify_user(message)
    message = tostring(message or "")
    Ui.toast(message)
    sys.log("[XXT-Device-GUI-Agent]", message)
    LCC.log(1, message)
end

local function require_config_value(value, message)
    if value == nil or value == "" then
        LCC.log(1, message)
        return false
    end
    return true
end

if not require_config_value(CONFIG.task, "请在运行前配置任务内容") then
    return os.exit()
end

if not require_config_value(CONFIG.model_url, "请在运行前配置模型接口 URL") then
    return os.exit()
end

if not require_config_value(CONFIG.model, "请在运行前配置模型名称") then
    return os.exit()
end

LCC.log(1, "开始执行：" .. CONFIG.task)

local function call_text_model(text, max_tokens)
    return Model.call_text_model(CONFIG, text, max_tokens)
end

local function append_step_log(step, model_text, repaired_text, screenshot_path, action, original_action, execution)
    Config.append_log(CONFIG, {
        time = Config.now_ms(),
        type = "step",
        step = step,
        action = action,
        original_action = original_action,
        model_response = model_text,
        repaired_response = repaired_text,
        screenshot = screenshot_path,
        execution = execution,
    })
end

local function coordinate_retry_instruction(parse_err, model_text, retry_index, action_type)
    action_type = Parser.normalize_action_type(action_type)
    if action_type == "" then
        action_type = "动作"
    end
    local slide_instruction = ""
    if action_type == "SLIDE" or action_type == "LONGPRESS_DRAG" then
        slide_instruction = "\n你上次可能只给了 point1 或 point2 中的一个，这种输出无效。请重新给出完整的 point1 和 point2；不要只补一个点。"
    end
    return [[
上一次输出无法执行，原因：]] .. tostring(parse_err or "坐标缺失") .. [[

你选择了需要屏幕坐标的 ]] .. tostring(action_type) .. [[，但没有提供明确的 0-1000 坐标。
]] .. slide_instruction .. [[
请重新观察当前截图，只输出一个可执行动作：
- 如果仍然选择 CLICK、LONGPRESS、DOUBLECLICK，必须包含 point:x,y。
- 如果选择 SLIDE 或 LONGPRESS_DRAG，必须包含 point1:x1,y1 和 point2:x2,y2。
- 坐标必须使用 0-1000 屏幕坐标，不要使用设备物理像素。
- 如果当前截图无法判断坐标，再使用 INFO 请求人工协助。

这是第 ]] .. tostring(retry_index) .. [[ 次坐标补全重试。

上一次原始输出：
]] .. tostring(model_text or "")
end

local function coordinate_retry_failed_action(parse_err, retry_count, action_type)
    local value = "模型连续 " .. tostring(retry_count) .. " 次输出 " .. tostring(action_type or "坐标类动作") .. " 但未提供明确的 0-1000 坐标。为避免误点，请人工确认当前页面后点击完成。"
    return {
        action = "INFO",
        value = value,
        explain = "坐标类动作多次缺少坐标，停止自动重问并转人工确认。",
        summary = "因 " .. tostring(parse_err or "坐标缺失") .. " 转人工确认。",
    }
end

local function parse_retry_history()
    return "已清空历史上下文。前文可能干扰了动作格式，请只根据用户目标和当前截图继续决策。"
end

local function parse_retry_instruction(parse_err, model_text, retry_index, context_reset)
    local reset_text = ""
    if context_reset then
        reset_text = "\n已清空历史上下文，本次只保留用户目标和当前截图。"
    end
    return [[
上一次输出无法解析，原因：]] .. tostring(parse_err or "解析失败") .. [[
]] .. reset_text .. [[

请重新观察当前截图，继续完成用户目标，但必须输出一个脚本可执行动作。
输出要求：
- action 必须是动作名本身，不要把 JSON 对象塞进 action 字段。
- 如果使用 CLICK、LONGPRESS、DOUBLECLICK，必须包含 point:x,y。
- 如果使用 SLIDE 或 LONGPRESS_DRAG，必须包含 point1:x1,y1 和 point2:x2,y2。
- 坐标必须使用 0-1000 屏幕坐标。
- 如果当前页面需要人工处理，输出 action:INFO 并给出具体 value。

这是第 ]] .. tostring(retry_index) .. [[ 次解析失败后的重问。

上一次原始输出：
]] .. tostring(model_text or "")
end

local function parse_retry_failed_action(parse_err, retry_count)
    retry_count = math.max(tonumber(retry_count) or 0, 1)
    local value = "模型连续 " .. tostring(retry_count) .. " 次输出无法解析。为避免无谓消耗，请人工确认当前页面后点击完成。"
    return {
        action = "INFO",
        value = value,
        explain = "动作格式连续无法解析，已清空上下文重问后仍未恢复，转人工确认。",
        summary = "因 " .. tostring(parse_err or "解析失败") .. " 转人工确认。",
    }
end

local function make_guard_action(original_action, reason)
    return {
        action = "INFO",
        value = reason,
        verify = Parser.field(original_action, "verify", "Verify"),
        note = Parser.field(original_action, "note", "Note"),
        explain = "请求人工确认",
        key_process = Parser.field(original_action, "key_process", "Key_process") or "检测到重复动作，暂停自动执行",
        summary = "检测到重复动作，已转人工确认：" .. Memory.action_signature(original_action),
    }
end

local function write_session_start()
    sys.mkdir_p(CONFIG.log_dir)
    file.writes(CONFIG.log_dir .. "/session.jsonl", "")
    Config.append_log(CONFIG, {
        time = Config.now_ms(),
        type = "session_start",
        session_id = CONFIG.session_id,
        task = CONFIG.task,
        model_url = CONFIG.model_url,
        model = CONFIG.model,
        temperature = CONFIG.temperature,
        max_tokens = CONFIG.max_tokens,
        max_steps = CONFIG.max_steps,
        parse_retry_count = CONFIG.parse_retry_count,
        parse_context_reset_count = CONFIG.parse_context_reset_count,
        coordinate_retry_count = CONFIG.coordinate_retry_count,
        enable_state_compression = CONFIG.enable_state_compression,
    })
end

local function compress_if_needed(step, memory)
    if not CONFIG.enable_state_compression or step % CONFIG.state_compression_interval ~= 0 then
        return
    end

    local compression_err = Memory.compress(CONFIG, memory, call_text_model)
    Config.append_log(CONFIG, {
        time = Config.now_ms(),
        type = compression_err and "compression_error" or "compression",
        step = step,
        error = compression_err,
        compressed_state = compression_err and nil or memory.compressed_state,
        recent_record_count = #memory.records,
    })
end

local function run_step(step, memory)
    local image_data_url, screenshot_path = Executor.capture_image_data_url(CONFIG, step)
    local history = Memory.build_history(CONFIG, memory)

    local model_text, repaired_text, action, parse_err
    local retry_instruction = nil
    local use_parse_reset_history = false
    local consecutive_parse_error_count = 0
    local last_missing_action_type = nil
    local consecutive_missing_count = 0
    local total_coordinate_retries = 0
    local max_recovery_model_calls = math.max(CONFIG.coordinate_retry_count * 4 + 1, CONFIG.coordinate_retry_count + 2, CONFIG.parse_retry_count + 2)
    for model_call_index = 1, max_recovery_model_calls do
        local model_err
        local active_history = use_parse_reset_history and parse_retry_history() or history
        model_text, model_err = Model.call_model(CONFIG, image_data_url, active_history, retry_instruction)
        if model_err then
            Config.append_log(CONFIG, { time = Config.now_ms(), type = "error", step = step, error = model_err })
            Ui.toast("Model error")
            return true, false, model_err
        end

        action, parse_err, repaired_text = Parser.parse_action_checked(CONFIG, call_text_model, model_text)
        if not parse_err then
            break
        end
        if not Parser.is_coordinate_missing_error(parse_err) then
            consecutive_parse_error_count = consecutive_parse_error_count + 1
            if consecutive_parse_error_count >= CONFIG.parse_context_reset_count then
                if not use_parse_reset_history then
                    LCC.log(1, "模型连续解析失败达到 " .. tostring(consecutive_parse_error_count) .. " 次，清空历史上下文后重问")
                end
                use_parse_reset_history = true
            end

            if consecutive_parse_error_count > CONFIG.parse_retry_count or model_call_index >= max_recovery_model_calls then
                LCC.log(1, "模型连续 " .. tostring(consecutive_parse_error_count) .. " 次输出无法解析，转人工确认：" .. tostring(parse_err))
                action = parse_retry_failed_action(parse_err, consecutive_parse_error_count)
                repaired_text = nil
                break
            end

            total_coordinate_retries = 0
            last_missing_action_type = nil
            consecutive_missing_count = 0
            LCC.log(1, "模型输出无法解析，连续第 " .. tostring(consecutive_parse_error_count) .. " 次，正在重问")
            Config.append_log(CONFIG, {
                time = Config.now_ms(),
                type = "parse_retry",
                step = step,
                retry = consecutive_parse_error_count,
                context_reset = use_parse_reset_history,
                model_response = model_text,
                repaired_response = repaired_text,
                error = parse_err,
            })
            image_data_url, screenshot_path = Executor.capture_image_data_url(CONFIG, tostring(step) .. "_parse_" .. tostring(consecutive_parse_error_count))
            retry_instruction = parse_retry_instruction(parse_err, model_text, consecutive_parse_error_count, use_parse_reset_history)
            sys.msleep(300)
        else
            local missing_action_type = Parser.coordinate_missing_action_type(parse_err) or "UNKNOWN"
            if missing_action_type == last_missing_action_type then
                consecutive_missing_count = consecutive_missing_count + 1
            else
                last_missing_action_type = missing_action_type
                consecutive_missing_count = 1
            end
            consecutive_parse_error_count = 0

            if consecutive_missing_count > CONFIG.coordinate_retry_count then
                LCC.log(1, "模型连续 " .. tostring(consecutive_missing_count) .. " 次输出 " .. missing_action_type .. " 但缺少坐标，转人工确认")
                action = coordinate_retry_failed_action(parse_err, consecutive_missing_count, missing_action_type)
                repaired_text = nil
                break
            end

            if model_call_index >= max_recovery_model_calls then
                LCC.log(1, "坐标缺失重问达到保护上限，转人工确认：" .. tostring(parse_err))
                action = coordinate_retry_failed_action(parse_err, consecutive_missing_count, missing_action_type)
                repaired_text = nil
                break
            end

            total_coordinate_retries = total_coordinate_retries + 1
            LCC.log(1, "模型输出 " .. missing_action_type .. " 缺少坐标，连续第 " .. tostring(consecutive_missing_count) .. " 次，正在第 " .. tostring(total_coordinate_retries) .. " 次重问坐标")
            Config.append_log(CONFIG, {
                time = Config.now_ms(),
                type = "coordinate_retry",
                step = step,
                retry = total_coordinate_retries,
                missing_action_type = missing_action_type,
                consecutive_missing_count = consecutive_missing_count,
                error = parse_err,
                model_response = model_text,
            })
            image_data_url, screenshot_path = Executor.capture_image_data_url(CONFIG, tostring(step) .. "_coordinate_" .. tostring(total_coordinate_retries))
            retry_instruction = coordinate_retry_instruction(parse_err, model_text, consecutive_missing_count, missing_action_type)
            sys.msleep(300)
        end
    end

    if not action then
        action = parse_retry_failed_action(parse_err or "模型恢复循环结束但没有可执行动作", math.max(consecutive_parse_error_count, consecutive_missing_count))
    end

    local original_action = action
    local guard_reason = Memory.detect_repetition(CONFIG, memory, action)
    if guard_reason then
        action = make_guard_action(original_action, guard_reason)
        Config.append_log(CONFIG, {
            time = Config.now_ms(),
            type = "guard",
            step = step,
            reason = guard_reason,
            original_action = original_action,
        })
    end

    local should_stop, execution = Executor.execute_action(CONFIG, LCC, action, image_data_url)
    local record = {
        step = step,
        action = action,
        execution = execution,
        screenshot = screenshot_path,
    }

    memory.records[#memory.records + 1] = record
    append_step_log(step, model_text, repaired_text, screenshot_path, action, original_action, execution)

    if should_stop then
        notify_user(execution.message or execution.error or execution.reason or "Stopped")
        return true, not execution.error, execution
    end

    compress_if_needed(step, memory)
    sys.msleep(CONFIG.delay_after_action_ms)
    return false, true, nil
end

local function run_agent()
    write_session_start()
    Ui.toast("Device Agent start: " .. CONFIG.task)

    local memory = Memory.new()
    for step = 1, CONFIG.max_steps do
        local stopped, ok, result = run_step(step, memory)
        if stopped then
            return ok, result
        end
    end

    local message = "达到最大步数：" .. tostring(CONFIG.max_steps)
    Config.append_log(CONFIG, { time = Config.now_ms(), type = "stop", reason = "MAX_STEPS_REACHED", message = message })
    notify_user(message)
    return false, message
end

local ok, result = run_agent()
return { ok = ok, result = result, log = CONFIG.log_dir .. "/session.jsonl" }
