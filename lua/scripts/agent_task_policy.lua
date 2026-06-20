local Parser = require("agent_parser")

local M = {}

local SEARCH_MISS_PATTERNS = {
    "未找到",
    "没有找到",
    "找不到",
    "无法找到",
    "没发现",
    "没有发现",
    "未发现",
    "未显示",
    "未成功显示",
    "未成功找到",
    "未能找到",
}

local SEARCH_GIVE_UP_PATTERNS = {
    "继续点击或滚动是无效",
    "继续滚动是无效",
    "滚动是无效",
    "继续探索无效",
    "继续查找无效",
    "报告这一情况",
    "请求进一步",
    "进一步指示",
    "无法继续",
    "不在这个列表",
    "没有其它",
    "没有其他",
    "没有更多",
    "找不到目标信息",
    "未找到目标信息",
}

local CONTINUE_SEARCH_PATTERNS = {
    "继续",
    "滚动",
    "滑动",
    "查找",
    "寻找",
    "浏览更多",
    "查看更多",
}

local SEARCH_TASK_PATTERNS = {
    "找",
    "找到",
    "查找",
    "寻找",
    "搜索",
    "滚动",
    "翻",
    "翻页",
    "列表",
}

local SCROLL_BOUNDARY_PATTERNS = {
    "仍停留",
    "没有变化",
    "无变化",
    "没有反应",
    "没反应",
    "不能滑动",
    "无法滑动",
    "不可滚动",
    "无法滚动",
    "不能滚动",
    "滑不动",
    "滚动不了",
    "到达底部",
    "已经到底",
    "列表底部",
    "到底部",
    "到达顶部",
    "已经到顶",
    "列表顶部",
    "到顶部",
    "边界",
    "没有新内容",
    "没有更多",
}

local SENSITIVE_PATTERNS = {
    "验证码",
    "手机号",
    "手机号码",
    "身份证",
    "登录",
    "支付",
    "密码",
}

local RETURN_CONTEXT_PATTERNS = {
    "返回",
    "回到",
    "上一级",
    "上一页",
    "进错",
    "点错",
    "错误地进入",
    "操作错误",
    "不符合",
    "不是我想要",
    "并不是",
}

local NAVIGATION_STOP_PATTERNS = {
    "然后",
    "接着",
    "再",
    "找到",
    "查找",
    "寻找",
    "搜索",
    "告诉",
    "滚动",
    "滑动",
    "翻页",
}

local NAVIGATION_PREFIXES = {
    "帮我",
    "请",
    "先",
    "打开",
    "进入",
    "前往",
    "去到",
    "转到",
    "点击",
    "点开",
    "选择",
}

local NAVIGATION_SEPARATORS = {
    "->",
    "=>",
    "→",
    "＞",
    ">",
    "—",
    "–",
    "－",
    "-",
}

local APP_LAUNCH_PREFIXES = {
    "帮我打开",
    "请打开",
    "先打开",
    "打开",
    "启动",
    "运行",
    "唤醒",
    "进入",
    "前往",
    "去到",
}

local APP_TARGET_STOP_PATTERNS = {
    "然后",
    "接着",
    "再",
    "下载",
    "安装",
    "更新",
    "搜索",
    "查找",
    "寻找",
    "找到",
    "签到",
    "登录",
    "购买",
    "播放",
    "发送",
    "编辑",
    "告诉",
}

local APP_TARGET_TRAILING_PUNCTUATION = {
    "，",
    ",",
    "。",
    "；",
    ";",
    "：",
    ":",
    "、",
}

function M.trim(text)
    text = tostring(text or "")
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    return text
end

local function starts_with(text, prefix)
    return string.sub(text, 1, #prefix) == prefix
end

local function strip_navigation_prefixes(text)
    local changed = true
    while changed do
        changed = false
        text = M.trim(text)
        for _, prefix in ipairs(NAVIGATION_PREFIXES) do
            if starts_with(text, prefix) then
                text = string.sub(text, #prefix + 1)
                changed = true
                break
            end
        end
    end
    return M.trim(text)
end

local function clip_navigation_segment(text)
    local first_stop = nil
    for _, pattern in ipairs(NAVIGATION_STOP_PATTERNS) do
        local index = string.find(text, pattern, 1, true)
        if index and (not first_stop or index < first_stop) then
            first_stop = index
        end
    end
    if first_stop == 1 then
        return nil, true
    end
    if first_stop then
        text = string.sub(text, 1, first_stop - 1)
    end
    text = strip_navigation_prefixes(text)
    if text == "" or #text > 48 then
        return nil, false
    end
    return text, false
end

local function first_plain_index(text, patterns)
    local first_stop = nil
    for _, pattern in ipairs(patterns) do
        local index = string.find(text, pattern, 1, true)
        if index and (not first_stop or index < first_stop) then
            first_stop = index
        end
    end
    return first_stop
end

local function replace_plain(text, needle, replacement)
    local out = {}
    local start_at = 1
    while start_at <= #text do
        local first, last = string.find(text, needle, start_at, true)
        if not first then
            out[#out + 1] = string.sub(text, start_at)
            break
        end
        out[#out + 1] = string.sub(text, start_at, first - 1)
        out[#out + 1] = replacement
        start_at = last + 1
    end
    return table.concat(out)
end

local function strip_trailing_app_punctuation(text)
    local changed = true
    while changed do
        changed = false
        text = M.trim(text)
        for _, suffix in ipairs(APP_TARGET_TRAILING_PUNCTUATION) do
            if suffix ~= "" and string.sub(text, -#suffix) == suffix then
                text = string.sub(text, 1, #text - #suffix)
                changed = true
                break
            end
        end
    end
    return M.trim(text)
end

local function clip_app_target(text)
    local first_stop = first_plain_index(text, APP_TARGET_STOP_PATTERNS)
    for _, separator in ipairs(NAVIGATION_SEPARATORS) do
        local index = string.find(text, separator, 1, true)
        if index and (not first_stop or index < first_stop) then
            first_stop = index
        end
    end
    if first_stop == 1 then
        return nil
    end
    if first_stop then
        text = string.sub(text, 1, first_stop - 1)
    end
    text = strip_trailing_app_punctuation(text)
    if text == "" or #text > 48 then
        return nil
    end
    return text
end

local function task_text(config)
    return tostring((config and config.task) or config or "")
end

local function contains_any_plain(text, patterns)
    for _, pattern in ipairs(patterns or {}) do
        if string.find(text, pattern, 1, true) then
            return true
        end
    end
    return false
end

local function task_repeat_direction(text)
    if contains_any_plain(text, { "上划", "上滑", "向上划", "向上滑", "往上划", "往上滑" }) then
        return "up", { 500, 850 }, { 500, 250 }
    end
    if contains_any_plain(text, { "下划", "下滑", "向下划", "向下滑", "往下划", "往下滑" }) then
        return "down", { 500, 250 }, { 500, 850 }
    end
    return nil
end

local function task_repeat_interval(text)
    local value = string.match(text, "每%s*(%d+)%s*秒")
    return tonumber(value)
end

local function task_repeat_count(text)
    local patterns = {
        "[划滑刷翻]%s*(%d+)%s*个?视频",
        "[划滑刷翻]%s*(%d+)%s*次",
        "(%d+)%s*个?视频",
    }
    for _, pattern in ipairs(patterns) do
        local value = string.match(text, pattern)
        value = tonumber(value)
        if value and value > 0 then
            return value
        end
    end
    return nil
end

function M.text_contains_any(text, patterns)
    local lower = string.lower(tostring(text or ""))
    for _, pattern in ipairs(patterns or {}) do
        if string.find(lower, string.lower(pattern), 1, true) then
            return true
        end
    end
    return false
end

function M.task_requests_search(config)
    local task = task_text(config)
    return M.text_contains_any(task or "", SEARCH_TASK_PATTERNS)
end

function M.contains_sensitive_request(text)
    return M.text_contains_any(text, SENSITIVE_PATTERNS)
end

function M.has_search_miss(text)
    return M.text_contains_any(text, SEARCH_MISS_PATTERNS)
end

function M.has_search_give_up(text)
    return M.text_contains_any(text, SEARCH_GIVE_UP_PATTERNS)
end

function M.has_continue_search(text)
    return M.text_contains_any(text, CONTINUE_SEARCH_PATTERNS)
end

function M.has_scroll_boundary(text)
    return M.text_contains_any(text, SCROLL_BOUNDARY_PATTERNS)
end

function M.search_feedback_can_continue(feedback)
    return not M.has_scroll_boundary(feedback)
        and (M.has_search_miss(feedback) or M.has_continue_search(feedback))
end

function M.search_slide_can_continue(config, action, feedback)
    local action_type = Parser.normalize_action_type(Parser.field(action, "action", "Action", "action_type", "type"))
    return action_type == "SLIDE"
        and M.task_requests_search(config)
        and M.search_feedback_can_continue(feedback)
end

function M.action_text(action)
    local parts = {}
    for _, key in ipairs({ "value", "text", "verify", "note", "explain", "summary", "key_process", "return" }) do
        local value = Parser.field(action, key, string.upper(string.sub(key, 1, 1)) .. string.sub(key, 2))
        if type(value) == "string" and value ~= "" then
            parts[#parts + 1] = value
        end
    end
    return table.concat(parts, " ")
end

function M.action_context_requests_return(action)
    return M.text_contains_any(M.action_text(action), RETURN_CONTEXT_PATTERNS)
end

function M.task_contains_visible_text(config, text)
    text = M.trim(text)
    if text == "" then
        return false
    end
    return string.find(task_text(config), text, 1, true) ~= nil
end

function M.task_navigation_targets(config)
    local task = task_text(config)
    local normalized = task
    for _, separator in ipairs(NAVIGATION_SEPARATORS) do
        normalized = replace_plain(normalized, separator, "\n")
    end

    local targets = {}
    local seen = {}
    for segment in string.gmatch(normalized .. "\n", "([^\n]*)\n") do
        local target, should_stop = clip_navigation_segment(segment)
        if target and not seen[target] then
            targets[#targets + 1] = target
            seen[target] = true
        end
        if should_stop then
            break
        end
    end
    return targets
end

function M.task_app_launch_target(config)
    local task = M.trim(task_text(config))
    if task == "" then
        return nil
    end
    for _, prefix in ipairs(APP_LAUNCH_PREFIXES) do
        if starts_with(task, prefix) then
            return clip_app_target(string.sub(task, #prefix + 1))
        end
    end
    return nil
end

function M.task_repeat_plan(config)
    local task = task_text(config)
    local direction, point1, point2 = task_repeat_direction(task)
    if not direction then
        return nil
    end
    local interval_seconds = task_repeat_interval(task)
    local max_count = task_repeat_count(task)
    if not interval_seconds or interval_seconds <= 0 or not max_count or max_count <= 0 then
        return nil
    end
    return {
        action = "SLIDE",
        point1 = point1,
        point2 = point2,
        direction = direction,
        interval_seconds = interval_seconds,
        max_count = max_count,
        status = "pending",
        completed_count = 0,
        unchanged_count = 0,
    }
end

function M.complete_has_result(action)
    if Parser.normalize_action_type(Parser.field(action, "action", "Action", "action_type", "type")) ~= "COMPLETE" then
        return false
    end
    local result = Parser.field(action, "return", "Return", "value", "Value")
    if type(result) ~= "string" or result == "" then
        return false
    end
    return not M.has_search_miss(result) and not M.has_search_give_up(result)
end

return M
