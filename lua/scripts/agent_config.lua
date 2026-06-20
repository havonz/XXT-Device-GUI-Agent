local M = {}

local ENABLED_VALUES = {
    ["开启"] = true,
    ["是"] = true,
    ["true"] = true,
    ["1"] = true,
    ["on"] = true,
    ["yes"] = true,
}

local DISABLED_VALUES = {
    ["关闭"] = true,
    ["否"] = true,
    ["false"] = true,
    ["0"] = true,
    ["off"] = true,
    ["no"] = true,
}

local function cfg_number(cfg, key, default_value)
    local value = tonumber(cfg[key])
    if value == nil then
        return default_value
    end
    return value
end

local function enabled_value(value, default_value)
    if value == nil or value == "" then
        return default_value
    end
    if type(value) == "boolean" then
        return value
    end
    if type(value) == "number" then
        return value ~= 0
    end
    value = string.lower(tostring(value))
    if ENABLED_VALUES[value] then
        return true
    end
    if DISABLED_VALUES[value] then
        return false
    end
    return default_value
end

local function cfg_enabled(cfg, key, default_value)
    return enabled_value(cfg[key], default_value)
end

local function decode_spawn_args(args)
    if type(args) ~= "table" then
        return args
    end
    local raw = args.spawn_args
    if type(raw) ~= "string" or raw == "" then
        return args
    end
    local decoded = json.decode(raw)
    if type(decoded) ~= "table" then
        return args
    end
    for key, value in pairs(args) do
        if key ~= "spawn_args" and decoded[key] == nil then
            decoded[key] = value
        end
    end
    return decoded
end

local function merge_number_arg(config, args, key, transform)
    local value = tonumber(args[key])
    if value == nil then
        return
    end
    config[key] = transform and transform(value) or value
end

local function merge_boolean_arg(config, args, key)
    if args[key] ~= nil then
        config[key] = enabled_value(args[key], config[key])
    end
end

local function merge_non_empty_string_arg(config, args, key)
    if type(args[key]) == "string" and args[key] ~= "" then
        config[key] = args[key]
    end
end

local function make_session_id()
    return os.date("%Y%m%d-%H%M%S") .. "-" .. utils.gen_uuid()
end

function M.normalize(config)
    if config.image_quality <= 0 or config.image_quality > 1 then
        config.image_quality = 0.55
    end
    if config.max_steps < 1 then
        config.max_steps = 1
    end
    if config.max_tokens < 256 then
        config.max_tokens = 256
    end
    if config.model_retry_count < 0 then
        config.model_retry_count = 0
    end
    if config.format_repair_retry_count < 0 then
        config.format_repair_retry_count = 0
    end
    if config.parse_retry_count < 1 then
        config.parse_retry_count = 1
    end
    if config.parse_context_reset_count < 1 then
        config.parse_context_reset_count = 1
    end
    if config.parse_retry_count < config.parse_context_reset_count then
        config.parse_retry_count = config.parse_context_reset_count
    end
    if config.coordinate_retry_count < 0 then
        config.coordinate_retry_count = 0
    end
    config.bad_action_retry_count = tonumber(config.bad_action_retry_count) or 2
    if config.bad_action_retry_count < 0 then
        config.bad_action_retry_count = 0
    end
    config.premature_info_retry_count = tonumber(config.premature_info_retry_count) or 1
    if config.premature_info_retry_count < 0 then
        config.premature_info_retry_count = 0
    end
    config.search_exploration_retry_count = tonumber(config.search_exploration_retry_count) or 1
    if config.search_exploration_retry_count < 0 then
        config.search_exploration_retry_count = 0
    end
    config.ineffective_action_retry_count = tonumber(config.ineffective_action_retry_count) or 1
    if config.ineffective_action_retry_count < 0 then
        config.ineffective_action_retry_count = 0
    end
    config.search_slide_threshold = tonumber(config.search_slide_threshold) or 3
    if config.search_slide_threshold < 1 then
        config.search_slide_threshold = 1
    end
    if config.recent_history_steps < 1 then
        config.recent_history_steps = 1
    end
    if config.state_compression_interval < 1 then
        config.state_compression_interval = 10
    end
    if config.state_compression_recent_window < 1 then
        config.state_compression_recent_window = 6
    end
    if config.state_compression_max_chars < 500 then
        config.state_compression_max_chars = 500
    end
    config.ui_element_observation_max_elements = tonumber(config.ui_element_observation_max_elements) or 80
    config.ui_element_observation_max_chars = tonumber(config.ui_element_observation_max_chars) or 12000
    if config.ui_element_observation_max_elements < 1 then
        config.ui_element_observation_max_elements = 1
    end
    if config.ui_element_observation_max_chars < 1000 then
        config.ui_element_observation_max_chars = 1000
    end
end

function M.from_ui(cfg)
    local config = {
        model_url = cfg["模型接口 URL"],
        api_key = cfg["API Key"] or "",
        model = cfg["模型名称"],
        task = cfg["任务内容"],
        temperature = cfg_number(cfg, "模型温度", 0.1),
        max_tokens = cfg_number(cfg, "单次响应最大 Token", 2048),
        max_steps = cfg_number(cfg, "最大步数", 20),
        request_timeout = cfg_number(cfg, "请求超时时间（秒）", 120),
        assist_timeout = cfg_number(cfg, "人工介入超时时间（秒）", 300),
        image_quality = cfg_number(cfg, "截图 JPEG 质量", 55) / 100,
        delay_after_action_ms = cfg_number(cfg, "动作后延迟毫秒数", 1200),
        model_retry_count = cfg_number(cfg, "模型请求重试次数", 2),
        format_repair_retry_count = cfg_number(cfg, "动作格式修复次数", 1),
        parse_retry_count = cfg_number(cfg, "解析失败重问次数", 8),
        parse_context_reset_count = cfg_number(cfg, "解析失败清上下文阈值", 3),
        coordinate_retry_count = cfg_number(cfg, "坐标缺失重问次数", 3),
        bad_action_retry_count = 2,
        premature_info_retry_count = 1,
        search_exploration_retry_count = 1,
        ineffective_action_retry_count = 1,
        search_slide_threshold = 3,
        recent_history_steps = cfg_number(cfg, "最近历史保留步数", 8),
        enable_state_compression = cfg_enabled(cfg, "启用历史压缩", true),
        state_compression_interval = cfg_number(cfg, "历史压缩间隔步数", 10),
        state_compression_recent_window = cfg_number(cfg, "压缩保留最近步数", 6),
        state_compression_max_chars = cfg_number(cfg, "压缩状态最大字符数", 3000),
        save_screenshots = cfg_enabled(cfg, "保存每步截图", false),
        enable_ui_element_observation = cfg_enabled(cfg, "每帧提供文本元素列表", false),
        ui_element_observation_max_elements = 80,
        ui_element_observation_max_chars = 12000,
        click_loop_threshold = 3,
        slide_loop_threshold = 5,
        same_action_loop_threshold = 4,
        action_cycle_threshold = 3,
        session_id = make_session_id(),
        log_root = XXT_LOG_PATH .. "/gelab-xxt-device-agent",
    }
    config.log_dir = config.log_root .. "/" .. config.session_id
    config.screenshot_dir = config.log_dir .. "/screens"
    M.normalize(config)
    return config
end

function M.merge_launch_args(config)
    local args = utils.launch_args()
    if type(args) ~= "table" then
        return
    end
    args = decode_spawn_args(args)
    merge_non_empty_string_arg(config, args, "task")
    merge_non_empty_string_arg(config, args, "model_url")
    merge_non_empty_string_arg(config, args, "model")
    if type(args.api_key) == "string" then
        config.api_key = args.api_key
    end

    merge_number_arg(config, args, "max_steps")
    merge_number_arg(config, args, "temperature")
    merge_number_arg(config, args, "max_tokens")
    merge_number_arg(config, args, "request_timeout")
    merge_number_arg(config, args, "image_quality", function(quality)
        if quality > 1 then
            quality = quality / 100
        end
        return quality
    end)
    merge_number_arg(config, args, "delay_after_action_ms")
    merge_number_arg(config, args, "assist_timeout")
    merge_number_arg(config, args, "recent_history_steps")
    merge_number_arg(config, args, "coordinate_retry_count")
    merge_number_arg(config, args, "model_retry_count")
    merge_number_arg(config, args, "format_repair_retry_count")
    merge_number_arg(config, args, "bad_action_retry_count")
    merge_number_arg(config, args, "premature_info_retry_count")
    merge_number_arg(config, args, "search_exploration_retry_count")
    merge_number_arg(config, args, "ineffective_action_retry_count")
    merge_number_arg(config, args, "search_slide_threshold")
    merge_number_arg(config, args, "parse_retry_count")
    merge_number_arg(config, args, "parse_context_reset_count")
    merge_number_arg(config, args, "ui_element_observation_max_elements")
    merge_number_arg(config, args, "ui_element_observation_max_chars")

    merge_boolean_arg(config, args, "enable_state_compression")
    merge_boolean_arg(config, args, "enable_ui_element_observation")
    merge_boolean_arg(config, args, "save_screenshots")
    M.normalize(config)
end

function M.append_log(config, record)
    sys.mkdir_p(config.log_dir)
    local line = json.encode(record) or "{}"
    file.appends(config.log_dir .. "/session.jsonl", line .. "\n")
end

return M
