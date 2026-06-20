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

function M.trim(text)
    text = tostring(text or "")
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    return text
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
    local task = type(config) == "table" and config.task or config
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
    return string.find(tostring((config and config.task) or ""), text, 1, true) ~= nil
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
