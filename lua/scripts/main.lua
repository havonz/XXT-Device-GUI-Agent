-- Device-side GELab-style GUI Agent for XXTouch.

local LCC = require("XXTLanControl")
local Config = require("agent_config")
local Executor = require("agent_executor")
local Memory = require("agent_memory")
local Model = require("agent_model")
local Parser = require("agent_parser")

while not LCC.connect() do
    sys.msleep(1000)
end

local cfg = LCC.get_ui_config() or {}
local CONFIG = Config.from_ui(cfg)

Config.merge_launch_args(CONFIG)
Config.normalize(CONFIG)

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
    local model_text, model_err = Model.call_model(CONFIG, image_data_url, history)
    if model_err then
        Config.append_log(CONFIG, { time = Config.now_ms(), type = "error", step = step, error = model_err })
        sys.toast("Model error")
        return true, false, model_err
    end

    local action, parse_err, repaired_text = Parser.parse_action_checked(CONFIG, call_text_model, model_text)
    if parse_err then
        Config.append_log(CONFIG, {
            time = Config.now_ms(),
            type = "error",
            step = step,
            model_response = model_text,
            repaired_response = repaired_text,
            error = parse_err,
        })
        sys.toast("Parse error")
        return true, false, parse_err
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
        sys.toast(tostring(execution.message or execution.error or execution.reason or "Stopped"))
        return true, not execution.error, execution
    end

    compress_if_needed(step, memory)
    sys.msleep(CONFIG.delay_after_action_ms)
    return false, true, nil
end

local function run_agent()
    write_session_start()
    sys.toast("Device Agent start: " .. CONFIG.task)

    local memory = Memory.new()
    for step = 1, CONFIG.max_steps do
        local stopped, ok, result = run_step(step, memory)
        if stopped then
            return ok, result
        end
    end

    local message = "达到最大步数：" .. tostring(CONFIG.max_steps)
    Config.append_log(CONFIG, { time = Config.now_ms(), type = "stop", reason = "MAX_STEPS_REACHED", message = message })
    sys.toast(message)
    return false, message
end

local ok, result = run_agent()
return { ok = ok, result = result, log = CONFIG.log_dir .. "/session.jsonl" }
