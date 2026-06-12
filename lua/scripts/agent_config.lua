local M = {}

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
    if value == "开启" or value == "是" or value == "true" or value == "1" or value == "on" or value == "yes" then
        return true
    end
    if value == "关闭" or value == "否" or value == "false" or value == "0" or value == "off" or value == "no" then
        return false
    end
    return default_value
end

local function cfg_enabled(cfg, key, default_value)
    return enabled_value(cfg[key], default_value)
end

local function now_ms_value()
    if sys and sys.mtime then
        return sys.mtime()
    end
    return math.floor(os.time() * 1000)
end

local function make_session_id()
    if utils and utils.gen_uuid then
        local uuid = utils.gen_uuid()
        if type(uuid) == "string" and uuid ~= "" then
            return os.date("%Y%m%d-%H%M%S") .. "-" .. uuid
        end
    end
    return os.date("%Y%m%d-%H%M%S") .. "-" .. tostring(now_ms_value())
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
        recent_history_steps = cfg_number(cfg, "最近历史保留步数", 8),
        enable_state_compression = cfg_enabled(cfg, "启用历史压缩", true),
        state_compression_interval = cfg_number(cfg, "历史压缩间隔步数", 10),
        state_compression_recent_window = cfg_number(cfg, "压缩保留最近步数", 6),
        state_compression_max_chars = cfg_number(cfg, "压缩状态最大字符数", 3000),
        save_screenshots = cfg_enabled(cfg, "保存每步截图", false),
        click_loop_threshold = 3,
        slide_loop_threshold = 5,
        same_action_loop_threshold = 4,
        session_id = make_session_id(),
        log_root = XXT_LOG_PATH .. "/gelab-xxt-device-agent",
    }
    config.log_dir = config.log_root .. "/" .. config.session_id
    config.screenshot_dir = config.log_dir .. "/screens"
    M.normalize(config)
    return config
end

function M.merge_launch_args(config)
    if not utils or not utils.launch_args then
        return
    end
    local args = utils.launch_args()
    if type(args) ~= "table" then
        return
    end
    if type(args.task) == "string" and args.task ~= "" then
        config.task = args.task
    end
    if tonumber(args.max_steps) then
        config.max_steps = tonumber(args.max_steps)
    end
    if tonumber(args.temperature) then
        config.temperature = tonumber(args.temperature)
    end
    if tonumber(args.max_tokens) then
        config.max_tokens = tonumber(args.max_tokens)
    end
    if type(args.model_url) == "string" and args.model_url ~= "" then
        config.model_url = args.model_url
    end
    if type(args.model) == "string" and args.model ~= "" then
        config.model = args.model
    end
    if type(args.api_key) == "string" then
        config.api_key = args.api_key
    end
    if tonumber(args.assist_timeout) then
        config.assist_timeout = tonumber(args.assist_timeout)
    end
    if tonumber(args.recent_history_steps) then
        config.recent_history_steps = tonumber(args.recent_history_steps)
    end
    if tonumber(args.coordinate_retry_count) then
        config.coordinate_retry_count = tonumber(args.coordinate_retry_count)
    end
    if tonumber(args.parse_retry_count) then
        config.parse_retry_count = tonumber(args.parse_retry_count)
    end
    if tonumber(args.parse_context_reset_count) then
        config.parse_context_reset_count = tonumber(args.parse_context_reset_count)
    end
    if args.enable_state_compression ~= nil then
        config.enable_state_compression = enabled_value(args.enable_state_compression, config.enable_state_compression)
    end
    M.normalize(config)
end

function M.now_ms()
    return now_ms_value()
end

function M.append_log(config, record)
    sys.mkdir_p(config.log_dir)
    local line = json.encode(record) or "{}"
    file.appends(config.log_dir .. "/session.jsonl", line .. "\n")
end

return M
