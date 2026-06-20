-- Device-side GELab-style GUI Agent for XXTouch.

local LCC = require("XXTLanControl")
local Config = require("agent_config")
local Executor = require("agent_executor")
local Memory = require("agent_memory")
local Model = require("agent_model")
local Observation = require("agent_observation")
local Parser = require("agent_parser")
local Policy = require("agent_task_policy")
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

local function append_step_log(step, model_text, repaired_text, screenshot_path, observation_meta, action, original_action, execution)
    Config.append_log(CONFIG, {
        time = sys.mtime(),
        type = "step",
        step = step,
        action = action,
        original_action = original_action,
        model_response = model_text,
        repaired_response = repaired_text,
        screenshot = screenshot_path,
        observation = observation_meta,
        execution = execution,
    })
end

local function coordinate_retry_instruction(parse_err, model_text, retry_index, action_type)
    action_type = Parser.normalize_action_type(action_type)
    if action_type == "" then
        action_type = "动作"
    end
    local slide_instruction = ""
    if Parser.is_two_point_action(action_type) then
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

local PARSE_RESET_HISTORY = "已清空历史上下文。前文可能干扰了动作格式，请只根据用户目标和当前截图继续决策。"

local function parse_retry_instruction(parse_err, model_text, retry_index, context_reset)
    local reset_text = ""
    local previous_output_text = [[

上一次原始输出：
]] .. tostring(model_text or "")
    if context_reset then
        reset_text = "\n已清空历史上下文，本次只保留用户目标和当前截图。不要复述历史步骤、上一次输出、[STEP]、screen_after_action、execution_result 或“当前手机屏幕截图如下”。"
        previous_output_text = [[

本次已不再提供上一次原始输出；它可能已经污染格式。请只根据当前截图和用户目标重新输出当前这一步。]]
    end
    return [[
上一次输出无法解析，原因：]] .. tostring(parse_err or "解析失败") .. [[
]] .. reset_text .. [[

请重新观察当前截图，继续完成用户目标，但必须输出一个脚本可执行动作。
输出要求：
- action 必须是动作名本身，不要把 JSON 对象塞进 action 字段。
- 只能输出一个 action 字段；不要在 key_process、summary 或其它字段里再次写 action。
- 如果使用 CLICK、LONGPRESS、DOUBLECLICK，必须包含 point:x,y。
- 如果使用 SLIDE 或 LONGPRESS_DRAG，必须包含 point1:x1,y1 和 point2:x2,y2。
- 坐标必须使用 0-1000 屏幕坐标。
- 如果当前页面需要人工处理，输出 action:INFO 并给出具体 value。

这是第 ]] .. tostring(retry_index) .. [[ 次解析失败后的重问。
]] .. previous_output_text
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

local fallback_search_slide_action

local function clicked_lower_screen(action)
    local action_type = Parser.normalize_action_type(Parser.field(action, "action", "Action", "action_type", "type"))
    if action_type ~= "CLICK" and action_type ~= "DOUBLECLICK" and action_type ~= "LONGPRESS" then
        return false
    end
    local _, y = Parser.point_value(Parser.field(action, "point", "Point"))
    return y ~= nil and y >= 350
end

local function bad_action_retry_instruction(reason, action, retry_index)
    local extra = ""
    if clicked_lower_screen(action) then
        extra = "\n- 这个错误动作点在列表主体区域，可能点到了目标之外的其它列表项。返回列表后如果目标文字不可见，不要再猜测点击其它行；应根据当前截图和历史中已验证无效的滑动方向，改用还没有被证明无效的 SLIDE 方向继续探索。"
    end
    return [[
候选动作被错误记忆拦截，不能执行。
原因：]] .. tostring(reason or "该动作此前导致错误页面或未达预期") .. [[

被拦截动作：]] .. Memory.action_signature(action) .. [[

请重新观察当前截图，继续完成用户目标，但必须换一个方案：
- 不要重复这个动作、点位或入口。
- 如果目标文字当前清楚可见，才点击目标文字所在行。
- 如果目标文字不可见，禁止按大概位置猜测点击；必须使用 SLIDE 查找，先根据当前列表已经滚到上方还是下方选择方向。]] .. extra .. [[
- 如果无法可靠判断，输出 action:INFO 并给出具体 value 请求人工协助。

这是第 ]] .. tostring(retry_index) .. [[ 次错误动作重问。
]]
end

local function bad_action_retry_failed_action(config, memory, reason, action, retry_count)
    local action_type = Parser.normalize_action_type(Parser.field(action, "action", "Action", "action_type", "type"))
    if action_type == "SLIDE" then
        local x1, y1 = Parser.point_value(Parser.field(action, "point1", "Point1"))
        local x2, y2 = Parser.point_value(Parser.field(action, "point2", "Point2"))
        if x1 and y1 and x2 and y2 then
            local reversed = {
                action = "SLIDE",
                point1 = { x2, y2 },
                point2 = { x1, y1 },
                auto_recovery = "bad_slide_reverse",
                verify = "候选滑动方向已经被错误记忆拦截，改用反方向验证。",
                note = "不再重复同方向滑动，改用反方向继续探索。",
                explain = "模型多次重复已知错误滑动，自动换成反方向 SLIDE。",
                key_process = "反方向滑动验证可滚动区域",
                summary = "因已知错误滑动重复，改用反方向 SLIDE。原因：" .. tostring(reason or "错误动作重复"),
            }
            local known_bad = Memory.detect_bad_action_reuse(config, memory, reversed)
            if not known_bad and not Memory.would_repeat_ineffective_action(config, memory, reversed) then
                return reversed
            end
        end
    end
    if Policy.task_requests_search(config) and action_type ~= "SLIDE" then
        return fallback_search_slide_action("模型多次提出已知错误点击；当前目标不可见时不应继续猜点，改为按未验证无效的方向滑动探索。原原因：" .. tostring(reason or "错误动作重复"), config, memory)
    end
    local value = "模型连续 " .. tostring(retry_count) .. " 次提出已知错误动作。为避免重复进入错误页面，请人工确认当前页面后点击完成。原因：" .. tostring(reason or "错误动作重复")
    return {
        action = "INFO",
        value = value,
        explain = "错误动作多次重复，停止自动重问并转人工确认。",
        summary = "因错误动作重复转人工确认。",
    }
end

local function click_hits_unrelated_visible_text(config, action, observation)
    if not Policy.task_requests_search(config) then
        return nil
    end
    local action_type = Parser.normalize_action_type(Parser.field(action, "action", "Action", "action_type", "type"))
    if action_type ~= "CLICK" and action_type ~= "DOUBLECLICK" and action_type ~= "LONGPRESS" then
        return nil
    end
    local x, y = Parser.point_value(Parser.field(action, "point", "Point"))
    if not x or not y then
        return nil
    end
    local text = Observation.text_at_point(observation, x, y)
    if Policy.action_context_requests_return(action) then
        if x <= 250 and y <= 160 then
            return nil
        end
        if text == "设置" or text == "返回" or text == "Back" then
            return nil
        end
    end
    if not text or text == "" then
        return nil
    end
    local action_text = Policy.action_text(action)
    if string.find(action_text, text, 1, true) then
        return nil
    end
    if text == "搜索栏" and (string.find(action_text, "搜索", 1, true) or string.find(action_text, "搜索框", 1, true)) then
        return nil
    end
    if Policy.task_contains_visible_text(config, text) then
        return nil
    end
    return "候选点击命中了当前可见文本“" .. text .. "”，但用户任务中没有这个目标；这很可能是在列表中猜点点到了无关条目。应先 SLIDE 查找任务中明确出现的目标文字。"
end

local POINT_ACTION_TYPES = {
    CLICK = true,
    DOUBLECLICK = true,
    LONGPRESS = true,
}

local function visible_navigation_target_action(config, action, observation)
    if not Policy.task_requests_search(config) then
        return nil
    end
    local action_type = Parser.normalize_action_type(Parser.field(action, "action", "Action", "action_type", "type"))
    if action_type == "COMPLETE" or action_type == "INFO" or action_type == "ABORT" or action_type == "BACK" then
        return nil
    end
    if action_type ~= "SLIDE" and not POINT_ACTION_TYPES[action_type] then
        return nil
    end

    local targets = Policy.task_navigation_targets(config)
    local target = Observation.find_visible_text_target(observation, targets, {
        skip_top_navigation = true,
        skip_first_top_title = true,
    })
    if not target then
        return nil
    end

    if POINT_ACTION_TYPES[action_type] then
        local x, y = Parser.point_value(Parser.field(action, "point", "Point"))
        local clicked_text = x and y and Observation.text_at_point(observation, x, y) or nil
        if clicked_text == target.text then
            return nil
        end
    end

    return {
        action = "CLICK",
        point = { target.point[1], target.point[2] },
        verify = "任务路径目标“" .. tostring(target.text) .. "”当前已经在结构化元素列表中可见，应直接点击该项。",
        note = "点击当前可见的任务路径目标“" .. tostring(target.text) .. "”。",
        explain = "模型候选动作没有命中已可见的路径目标，自动改为点击该目标。",
        key_process = "点击可见路径目标",
        summary = "当前可见任务路径目标“" .. tostring(target.text) .. "”，优先点击而不是继续滑动或猜点。",
    }, target
end

local function search_exploration_reason(config, memory, model_text, action)
    if not Policy.task_requests_search(config) then
        return nil
    end
    local action_type = action and Parser.normalize_action_type(Parser.field(action, "action", "Action", "action_type", "type")) or ""
    if Policy.complete_has_result(action) then
        return nil
    end
    local text = tostring(model_text or "") .. " " .. Policy.action_text(action)
    if Policy.contains_sensitive_request(text) then
        return nil
    end
    if action_type == "SLIDE" then
        return nil
    end
    local has_miss = Policy.has_search_miss(text)
    local gives_up = Policy.has_search_give_up(text)
    if not has_miss and not gives_up then
        return nil
    end
    if action_type == "INFO" or action_type == "ABORT" or action_type == "COMPLETE" or gives_up then
        return "搜索任务尚未证明已穷尽，但模型正在得出找不到或不能继续探索的结论。只要页面仍可能向下或向上翻，就应该继续探索；只有滑动到边界或同方向滑动进入无效循环后，才允许转人工或报告找不到。"
    end
    return nil
end

local function recent_slide_count(memory)
    local records = (memory and memory.records) or {}
    local count = 0
    for i = #records, 1, -1 do
        local prev_type = Parser.normalize_action_type(Parser.field(records[i].action, "action", "Action", "action_type", "type"))
        if prev_type == "SLIDE" then
            count = count + 1
        else
            break
        end
    end
    return count
end

local function premature_info_reason(config, memory, action)
    if Parser.normalize_action_type(Parser.field(action, "action", "Action", "action_type", "type")) ~= "INFO" then
        return nil
    end
    if not Policy.task_requests_search(config) then
        return nil
    end
    local info_text = Policy.action_text(action)
    if Policy.contains_sensitive_request(info_text) then
        return nil
    end
    if not Policy.text_contains_any(info_text, { "未找到", "没有找到", "找不到", "无法找到", "没发现", "继续寻找", "继续滚动", "继续翻", "请问", "确认下一步" }) then
        return nil
    end
    local slides = recent_slide_count(memory)
    local threshold = math.max(tonumber(config.search_slide_threshold) or 3, 1)
    if slides >= threshold then
        return nil
    end
    return "当前任务是查找信息，候选 INFO 只是因为当前可视区域未找到目标；最近仅连续滑动 " .. tostring(slides) .. " 次，未达到查找阈值 " .. tostring(threshold) .. " 次。应继续用未被证明无效的滑动方向查找，而不是询问用户。"
end

local function premature_info_retry_instruction(reason, retry_index)
    return [[
候选 INFO 被拦截，当前不应请求人工。
原因：]] .. tostring(reason or "当前只是未在可视区域找到目标") .. [[

请重新观察当前截图并继续完成任务：
- 如果目标文字或结果当前可见，点击或 COMPLETE。
- 如果目标仍不可见，继续使用还没有被证明无效的 SLIDE 方向查找；如果刚才同方向滑动后界面没有变化，再换反方向或改变滑动幅度。
- “当前可视区域未找到”不等于任务失败；列表可能需要翻多页。
- 只有已经到达列表底部、连续多次滑动无变化、遇到敏感输入/登录/验证码，才使用 INFO。

这是第 ]] .. tostring(retry_index) .. [[ 次过早 INFO 重问。
]]
end

local function normalize_search_direction(direction)
    if direction == "up" or direction == "reveal_above" then
        return "reveal_above"
    end
    return "reveal_below"
end

local function opposite_search_direction(direction)
    direction = normalize_search_direction(direction)
    return direction == "reveal_above" and "reveal_below" or "reveal_above"
end

local function search_slide_action(reason, direction)
    direction = normalize_search_direction(direction)
    local point1 = { 500, 850 }
    local point2 = { 500, 250 }
    local direction_text = "向下滚动"
    local gesture_text = "手指向上滑动，露出下方内容"
    if direction == "reveal_above" then
        point1 = { 500, 250 }
        point2 = { 500, 850 }
        direction_text = "向上滚动"
        gesture_text = "手指向下滑动，露出上方内容"
    end
    return {
        action = "SLIDE",
        point1 = point1,
        point2 = point2,
        verify = "上一步未在当前可视区域找到目标，但这不代表任务失败。",
        note = "继续" .. direction_text .. "查找目标信息；" .. gesture_text .. "。",
        explain = "当前是查找类任务，可能需要翻多页或反向检查，因此自动继续探索。",
        key_process = "继续翻页查找目标信息",
        summary = "因搜索未穷尽的结论被拦截，继续" .. direction_text .. "查找。原因：" .. tostring(reason or "目标尚未出现"),
    }
end

local function copy_action(action)
    local out = {}
    for key, value in pairs(action or {}) do
        out[key] = value
    end
    return out
end

local function repeat_slide_matches_plan(plan, action)
    if type(plan) ~= "table" or Parser.normalize_action_type(Parser.field(action, "action", "Action", "action_type", "type")) ~= "SLIDE" then
        return false
    end
    local _, y1 = Parser.point_value(Parser.field(action, "point1", "Point1"))
    local _, y2 = Parser.point_value(Parser.field(action, "point2", "Point2"))
    if not y1 or not y2 or y1 == y2 then
        return false
    end
    if plan.direction == "up" then
        return y1 > y2
    end
    if plan.direction == "down" then
        return y1 < y2
    end
    return false
end

local function repeat_direction_text(plan)
    return plan and plan.direction == "down" and "下划" or "上划"
end

local function repeat_task_wait_action(plan)
    return {
        action = "WAIT",
        value = tostring(plan.interval_seconds),
        auto_recovery = "repeat_task",
        repeat_task_phase = "wait",
        verify = "上一轮计划内" .. repeat_direction_text(plan) .. "已使画面变化，按用户要求等待指定间隔。",
        note = "重复任务进度：" .. tostring(plan.completed_count or 0) .. "/" .. tostring(plan.max_count or "?") .. "。",
        explain = "用户要求每 " .. tostring(plan.interval_seconds) .. " 秒执行一次滑动，自动等待后继续。",
        key_process = "重复任务等待间隔",
        summary = "已完成 " .. tostring(plan.completed_count or 0) .. " 次" .. repeat_direction_text(plan) .. "，等待 " .. tostring(plan.interval_seconds) .. " 秒后继续。",
    }
end

local function repeat_task_slide_action(plan)
    return {
        action = "SLIDE",
        point1 = { plan.point1[1], plan.point1[2] },
        point2 = { plan.point2[1], plan.point2[2] },
        auto_recovery = "repeat_task",
        repeat_task_phase = "slide",
        verify = "上一轮等待已完成，继续执行用户要求的重复" .. repeat_direction_text(plan) .. "。",
        note = "重复任务进度：" .. tostring(plan.completed_count or 0) .. "/" .. tostring(plan.max_count or "?") .. "。",
        explain = "用户明确要求重复滑动，自动按计划执行下一次。",
        key_process = "执行重复" .. repeat_direction_text(plan),
        summary = "按重复任务计划继续执行第 " .. tostring((plan.completed_count or 0) + 1) .. " 次" .. repeat_direction_text(plan) .. "。",
    }
end

local function repeat_task_complete_action(plan)
    return {
        action = "COMPLETE",
        ["return"] = "重复滑动任务已完成，已按要求" .. repeat_direction_text(plan) .. " " .. tostring(plan.completed_count or plan.max_count or 0) .. " 次。",
        auto_recovery = "repeat_task",
        repeat_task_phase = "complete",
        verify = "重复滑动次数已达到用户要求。",
        note = "重复任务进度：" .. tostring(plan.completed_count or 0) .. "/" .. tostring(plan.max_count or "?") .. "。",
        explain = "受控循环计数已达到目标次数，报告任务完成。",
        key_process = "重复任务完成",
        summary = "重复滑动任务已达到目标次数。",
    }
end

local function repeat_task_meta(plan, reason)
    return {
        kind = "repeat_task",
        reason = reason,
        completed_count = plan.completed_count or 0,
        max_count = plan.max_count,
        interval_seconds = plan.interval_seconds,
        direction = plan.direction,
        status = plan.status,
    }
end

local function set_repeat_plan_status(plan, status, reason)
    if not plan or plan.status == status and plan.pause_reason == reason then
        return
    end
    plan.status = status
    plan.pause_reason = reason
    Config.append_log(CONFIG, {
        time = sys.mtime(),
        type = "repeat_task_state",
        status = status,
        reason = reason,
        completed_count = plan.completed_count or 0,
        max_count = plan.max_count,
        interval_seconds = plan.interval_seconds,
        direction = plan.direction,
    })
end

local function update_repeat_plan_from_latest(memory)
    local plan = memory and memory.repeat_plan
    if type(plan) ~= "table" or plan.status == "completed" then
        return
    end
    local records = memory.records or {}
    local latest = records[#records]
    if type(latest) ~= "table" or latest.repeat_plan_seen then
        return
    end
    local action_type = Parser.normalize_action_type(Parser.field(latest.action, "action", "Action", "action_type", "type"))
    if action_type == "WAIT" and Parser.field(latest.action, "auto_recovery", "Auto_recovery") == "repeat_task" then
        latest.repeat_plan_seen = true
        if latest.execution and latest.execution.error then
            set_repeat_plan_status(plan, "paused", "计划内等待执行失败：" .. tostring(latest.execution.error))
            return
        end
        plan.next_action = "SLIDE"
        return
    end
    if action_type ~= "SLIDE" or not repeat_slide_matches_plan(plan, latest.action) then
        latest.repeat_plan_seen = true
        return
    end

    latest.repeat_plan_seen = true
    if latest.execution and latest.execution.error then
        set_repeat_plan_status(plan, "paused", "计划内滑动执行失败：" .. tostring(latest.execution.error))
        return
    end

    local change_status = latest.screen_change and latest.screen_change.status
    if change_status == "unchanged" then
        if plan.status == "active" then
            plan.unchanged_count = (tonumber(plan.unchanged_count) or 0) + 1
            if plan.unchanged_count >= 2 then
                set_repeat_plan_status(plan, "paused", "计划内滑动连续 2 次未改变画面")
            else
                plan.next_action = "WAIT"
            end
        end
        return
    end

    if change_status ~= "changed" then
        if plan.status == "active" then
            set_repeat_plan_status(plan, "paused", "计划内滑动后的画面变化无法确认")
        end
        return
    end

    plan.unchanged_count = 0
    plan.completed_count = (tonumber(plan.completed_count) or 0) + 1
    if plan.status ~= "active" then
        set_repeat_plan_status(plan, "active", "检测到计划内滑动已成功改变画面，开始受控重复循环")
    end
    if plan.completed_count >= plan.max_count then
        plan.next_action = "COMPLETE"
        set_repeat_plan_status(plan, "completed", "重复滑动次数已达到目标")
    else
        plan.next_action = "WAIT"
    end
end

local function automatic_repeat_task_action(config, memory)
    local plan = memory and memory.repeat_plan
    if type(plan) ~= "table" then
        return nil
    end
    if plan.status == "completed" or plan.next_action == "COMPLETE" or (tonumber(plan.completed_count) or 0) >= (tonumber(plan.max_count) or math.huge) then
        plan.next_action = "COMPLETE"
        return repeat_task_complete_action(plan), repeat_task_meta(plan, "重复滑动次数已达到用户要求，自动完成。")
    end
    if plan.status ~= "active" then
        return nil
    end
    if plan.next_action == "WAIT" then
        plan.next_action = nil
        return repeat_task_wait_action(plan), repeat_task_meta(plan, "计划内滑动已生效，按用户要求等待间隔。")
    end
    if plan.next_action == "SLIDE" then
        plan.next_action = nil
        return repeat_task_slide_action(plan), repeat_task_meta(plan, "等待间隔已完成，自动执行下一次计划内滑动。")
    end
    return nil
end

local function action_search_direction(action)
    if Parser.normalize_action_type(Parser.field(action, "action", "Action", "action_type", "type")) ~= "SLIDE" then
        return nil
    end
    local _, y1 = Parser.point_value(Parser.field(action, "point1", "Point1"))
    local _, y2 = Parser.point_value(Parser.field(action, "point2", "Point2"))
    if not y1 or not y2 or y1 == y2 then
        return nil
    end
    if y1 > y2 then
        return "reveal_below"
    end
    return "reveal_above"
end

local AUTO_CONTINUE_RECOVERY = {
    bad_slide_reverse = true,
    continue_effective_slide = true,
}

local function automatic_search_continuation_action(config, memory, observation)
    if not Policy.task_requests_search(config) then
        return nil
    end
    local records = (memory and memory.records) or {}
    local latest = records[#records]
    local latest_action = latest and latest.action
    if type(latest_action) ~= "table" or not AUTO_CONTINUE_RECOVERY[latest_action.auto_recovery] then
        return nil
    end
    if not (type(latest.screen_change) == "table" and latest.screen_change.status == "changed") then
        return nil
    end

    local target_action, target = visible_navigation_target_action(config, { action = "SLIDE" }, observation)
    if target_action then
        target_action.auto_recovery = "visible_navigation_target"
        return target_action, {
            kind = "visible_target",
            target = target,
            reason = "自动恢复滑动后发现任务路径目标已可见，直接点击目标。",
        }
    end

    if not action_search_direction(latest_action) then
        return nil
    end
    local action = copy_action(latest_action)
    action.auto_recovery = "continue_effective_slide"
    action.verify = "上一轮自动恢复滑动后截图主内容已有变化，说明该方向仍可继续探索。"
    action.note = "当前目标尚未在结构化元素列表中可见，继续沿最近有效滑动方向查找。"
    action.explain = "避免让模型反复提出已证明无效的相反方向；先延续已验证有效的探索方向。"
    action.key_process = "沿最近有效方向继续查找"
    action.summary = "自动延续上一轮已验证有效的滑动方向，继续查找任务路径目标。"
    return action, {
        kind = "continue_slide",
        reason = "上一轮自动恢复滑动有效，目标仍不可见，继续同方向探索。",
    }
end

local function compact_text(text)
    text = tostring(text or "")
    text = string.lower(text)
    text = string.gsub(text, "%s+", "")
    return text
end

local function has_attempted_awake(memory, app_name)
    local target = compact_text(app_name)
    if target == "" then
        return true
    end
    if type(memory) == "table" and type(memory.app_awake_attempted) == "table" and memory.app_awake_attempted[target] then
        return true
    end
    for _, record in ipairs((memory and memory.records) or {}) do
        local action = record and record.action
        local action_type = Parser.normalize_action_type(Parser.field(action, "action", "Action", "action_type", "type"))
        if action_type == "AWAKE" then
            local value = Parser.field(action, "value", "Value", "app", "App")
            if compact_text(value) == target then
                return true
            end
        end
    end
    return false
end

local function automatic_app_awake_action(config, memory)
    local app_name = Policy.task_app_launch_target(config)
    if not app_name or has_attempted_awake(memory, app_name) then
        return nil
    end
    if type(memory) == "table" then
        memory.app_awake_attempted = memory.app_awake_attempted or {}
        memory.app_awake_attempted[compact_text(app_name)] = true
    end
    return {
        action = "AWAKE",
        value = app_name,
        auto_recovery = "task_app_awake",
        verify = "用户任务开头明确要求打开应用，应优先使用语义启动而不是在主屏猜测图标。",
        note = "先用 AWAKE 打开“" .. tostring(app_name) .. "”。",
        explain = "主屏图标可能分页、改名或被误认；明确 App 名称时直接使用应用启动动作更可靠。",
        key_process = "语义启动目标应用",
        summary = "任务要求打开“" .. tostring(app_name) .. "”，自动优先执行 AWAKE。",
    }, {
        kind = "app_awake",
        app_name = app_name,
        reason = "任务开头明确要求打开应用，自动优先使用 AWAKE。",
    }
end

local function recent_effective_search_direction(memory)
    local records = (memory and memory.records) or {}
    for i = #records, 1, -1 do
        local direction = action_search_direction(records[i].action)
        if direction then
            local change = records[i].screen_change
            if type(change) == "table" and change.status == "changed" then
                return direction
            end
            if type(change) == "table" and change.status == "unchanged" then
                return nil
            end
        end
    end
    return nil
end

fallback_search_slide_action = function(reason, config, memory, preferred_direction)
    local directions = {}
    if preferred_direction then
        local normalized = normalize_search_direction(preferred_direction)
        directions[#directions + 1] = normalized
        directions[#directions + 1] = opposite_search_direction(normalized)
    else
        local recent_direction = recent_effective_search_direction(memory)
        if recent_direction then
            directions[#directions + 1] = recent_direction
            directions[#directions + 1] = opposite_search_direction(recent_direction)
        else
            directions[#directions + 1] = "reveal_below"
            directions[#directions + 1] = "reveal_above"
        end
    end
    for _, direction in ipairs(directions) do
        local slide_action = search_slide_action(reason, direction)
        local known_bad = Memory.detect_bad_action_reuse(config, memory, slide_action)
        if not known_bad and not Memory.would_repeat_ineffective_action(config, memory, slide_action) then
            return slide_action
        end
    end
    return {
        action = "INFO",
        value = "已尝试继续探索，但向下和向上滑动都可能进入无效循环。请人工确认当前页面是否还有可滚动内容，完成后点击完成。原因：" .. tostring(reason or "搜索探索已受限"),
        explain = "搜索探索方向都进入无效循环，转人工确认。",
        summary = "因上下方向探索都受限转人工确认。",
    }
end

local function search_exploration_retry_instruction(reason, retry_index)
    return [[
候选结论被拦截，当前不能直接说找不到。
原因：]] .. tostring(reason or "搜索尚未穷尽") .. [[

请重新观察当前截图并继续完成任务：
- 如果目标文字或目标值当前可见，点击对应项或 COMPLETE。
- 如果目标不可见，但页面可能还能向下或向上翻，必须使用 SLIDE 继续探索。
- 不要把“当前可见区域没看到”当成“整个页面不存在”。
- 如果刚才向下滑动后没有变化，尝试反方向或更短距离验证边界；如果仍不能滚动，再用 INFO 请求人工。
- 不要输出“继续滚动无效”“请求进一步指示”“找不到”之类结论，除非已经证明上下方向都不可继续。

这是第 ]] .. tostring(retry_index) .. [[ 次搜索探索重问。
]]
end

local function ineffective_action_retry_instruction(reason, action, retry_index)
    local action_type = Parser.normalize_action_type(Parser.field(action, "action", "Action", "action_type", "type"))
    local extra = ""
    if action_type == "SLIDE" then
        extra = "\n- 刚刚这个 SLIDE 执行后界面没有发生有效变化，说明这个滑动方向/幅度可能无效；不要重复同方向同距离 SLIDE，优先尝试反方向、缩短或改变滑动幅度、点击当前可见的其它入口，或返回上级重新定位。"
    else
        extra = "\n- 刚刚这个操作执行后界面没有发生有效变化，目标可能只是状态文字、静态字段或禁用项；不要再次操作同一位置或同一控件，改点其它可见入口、返回上级或换一种操作。"
        if Policy.action_context_requests_return(action) then
            extra = extra .. "\n- 如果当前是在错误页面且需要返回，但可见返回按钮点位不可靠，可以改用 action:BACK 返回上一页。"
        end
    end
    return [[
候选动作被无效循环拦截，暂不执行。
原因：]] .. tostring(reason or "该动作已重复执行但没有产生有效进展") .. [[

被拦截动作：]] .. Memory.action_signature(action) .. [[

请重新观察当前截图，继续完成用户目标，但必须换一个方案：
- 不要重复这个动作签名、相同点位、相同滑动方向或相同按键。
- 先判断上一步操作之后界面有没有变化；如果没有变化，本轮必须转换思路，尝试其它操作。
- 不要把静态标签、字段值、状态文字当成按钮。
- 如果目标文字当前可见且可点击，点击对应行的可交互区域；如果不可见，使用合适方向的 SLIDE 查找。]] .. extra .. [[
- 如果无法可靠判断下一步，输出 action:INFO 并说明当前被哪个无效动作卡住。

这是第 ]] .. tostring(retry_index) .. [[ 次无效动作重问。
]]
end

local function ineffective_action_failed_action(config, memory, reason, action, retry_count)
    local action_type = Parser.normalize_action_type(Parser.field(action, "action", "Action", "action_type", "type"))
    if action_type ~= "SLIDE" and Policy.action_context_requests_return(action) then
        return {
            action = "BACK",
            verify = "候选动作重复无效，且当前上下文显示需要从错误页面返回。",
            note = "使用系统返回手势回到上一页，再重新规划。",
            explain = "模型已多次尝试同一无效点位返回，改用 BACK 避免继续误点。",
            key_process = "从错误页面返回上一页",
            summary = "因无效动作循环且上下文要求返回，改用 BACK。原因：" .. tostring(reason or "无效动作循环"),
        }
    end
    if Policy.task_requests_search(config) and action_type ~= "SLIDE" then
        return fallback_search_slide_action("候选动作重复无效，疑似把静态文字或状态字段当作按钮；改为继续滑动查找。原原因：" .. tostring(reason or "无效动作循环"), config, memory)
    end
    local value = "模型连续 " .. tostring(retry_count) .. " 次提出无效循环动作 " .. Memory.action_signature(action) .. "。为避免继续重复无效操作，请人工确认当前页面后点击完成。原因：" .. tostring(reason or "无效动作循环")
    return {
        action = "INFO",
        value = value,
        explain = "动作重复无效且自动换方案未恢复，停止继续执行同类动作。",
        summary = "因无效动作循环转人工确认。",
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

local function complete_needs_confirmation(memory)
    local records = (memory and memory.records) or {}
    local latest = records[#records]
    return not (type(latest) == "table"
        and type(latest.execution) == "table"
        and latest.execution.reason == "COMPLETE_CONFIRMATION_PENDING")
end

local function complete_confirmation_execution(action)
    return {
        executed = "complete_confirmation_pending",
        reason = "COMPLETE_CONFIRMATION_PENDING",
        message = "模型首次报告任务完成，已等待下一帧重新确认。",
        proposed_message = Parser.field(action, "return", "Return", "value", "Value") or "完成",
    }
end

local function write_session_start()
    sys.mkdir_p(CONFIG.log_dir)
    file.writes(CONFIG.log_dir .. "/session.jsonl", "")
    Config.append_log(CONFIG, {
        time = sys.mtime(),
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
        bad_action_retry_count = CONFIG.bad_action_retry_count,
        premature_info_retry_count = CONFIG.premature_info_retry_count,
        search_exploration_retry_count = CONFIG.search_exploration_retry_count,
        ineffective_action_retry_count = CONFIG.ineffective_action_retry_count,
        search_slide_threshold = CONFIG.search_slide_threshold,
        repetition_guard_mode = CONFIG.repetition_guard_mode,
        enable_state_compression = CONFIG.enable_state_compression,
        enable_ui_element_observation = CONFIG.enable_ui_element_observation,
        ui_element_observation_max_elements = CONFIG.ui_element_observation_max_elements,
        repeat_plan = CONFIG.repeat_plan,
    })
end

local function capture_frame(step)
    local image_data_url, screenshot_path = Executor.capture_image_data_url(CONFIG, step)
    local observation = Observation.capture(CONFIG)
    return image_data_url, screenshot_path, Observation.to_prompt(observation), Observation.meta(observation), observation
end

local function update_last_screen_change(memory, current_screenshot_path)
    local records = (memory and memory.records) or {}
    local latest = records[#records]
    if not latest or latest.screen_change or not latest.screenshot or not current_screenshot_path then
        return nil
    end
    latest.screen_change = Memory.compare_screenshots(latest.screenshot, current_screenshot_path)
    Config.append_log(CONFIG, {
        time = sys.mtime(),
        type = "screen_change",
        step = latest.step,
        action = latest.action,
        before = latest.screenshot,
        after = current_screenshot_path,
        result = latest.screen_change,
    })
    return latest.screen_change
end

local function compress_if_needed(step, memory)
    if not CONFIG.enable_state_compression or step % CONFIG.state_compression_interval ~= 0 then
        return
    end

    local compression_err = Memory.compress(CONFIG, memory, call_text_model)
    Config.append_log(CONFIG, {
        time = sys.mtime(),
        type = compression_err and "compression_error" or "compression",
        step = step,
        error = compression_err,
        compressed_state = compression_err and nil or memory.compressed_state,
        recent_record_count = #memory.records,
    })
end

local function run_step(step, memory)
    local image_data_url, screenshot_path, observation_prompt, observation_meta, observation = capture_frame(step)
    update_last_screen_change(memory, screenshot_path)
    update_repeat_plan_from_latest(memory)
    local history = Memory.build_history(CONFIG, memory)

    local model_text, repaired_text, action, parse_err
    local retry_instruction = nil
    local use_parse_reset_history = false
    local consecutive_parse_error_count = 0
    local last_missing_action_type = nil
    local consecutive_missing_count = 0
    local total_coordinate_retries = 0
    local consecutive_bad_action_count = 0
    local consecutive_premature_info_count = 0
    local consecutive_search_exploration_count = 0
    local consecutive_ineffective_action_count = 0
    local max_recovery_model_calls = math.max(CONFIG.coordinate_retry_count * 4 + 1, CONFIG.coordinate_retry_count + 2, CONFIG.parse_retry_count + 2, CONFIG.bad_action_retry_count + 2, CONFIG.premature_info_retry_count + 2, CONFIG.search_exploration_retry_count + 2, CONFIG.ineffective_action_retry_count + 2)

    local function reset_coordinate_retry_counts()
        total_coordinate_retries = 0
        last_missing_action_type = nil
        consecutive_missing_count = 0
    end

    local function reset_recovery_counts(active)
        if active ~= "parse" then
            consecutive_parse_error_count = 0
        end
        if active ~= "coordinate" then
            reset_coordinate_retry_counts()
        end
        if active ~= "bad_action" then
            consecutive_bad_action_count = 0
        end
        if active ~= "premature_info" then
            consecutive_premature_info_count = 0
        end
        if active ~= "search_exploration" then
            consecutive_search_exploration_count = 0
        end
        if active ~= "ineffective_action" then
            consecutive_ineffective_action_count = 0
        end
    end

    local function prepare_retry_frame(label, instruction)
        image_data_url, screenshot_path, observation_prompt, observation_meta, observation = capture_frame(label)
        retry_instruction = instruction
        sys.msleep(300)
    end

    local automatic_action, automatic_meta = automatic_repeat_task_action(CONFIG, memory)
    local automatic_kind = "repeat_task_action"
    if not automatic_action then
        automatic_action, automatic_meta = automatic_app_awake_action(CONFIG, memory)
        automatic_kind = "automatic_app_awake"
    end
    if not automatic_action then
        automatic_action, automatic_meta = automatic_search_continuation_action(CONFIG, memory, observation)
        automatic_kind = "automatic_search_continuation"
    end
    if automatic_action and Parser.validate_action(automatic_action) then
        action = automatic_action
        model_text = "[automatic] " .. tostring(automatic_meta and automatic_meta.reason or "自动延续搜索探索")
        repaired_text = automatic_kind
        Config.append_log(CONFIG, {
            time = sys.mtime(),
            type = automatic_kind == "repeat_task_action" and "repeat_task_action" or "automatic_action",
            step = step,
            action = action,
            meta = automatic_meta,
        })
    end

    if not action then
    for model_call_index = 1, max_recovery_model_calls do
        local model_err
        local active_history = use_parse_reset_history and PARSE_RESET_HISTORY or history
        model_text, model_err = Model.call_model(CONFIG, image_data_url, active_history, retry_instruction, observation_prompt)
        if model_err then
            Config.append_log(CONFIG, { time = sys.mtime(), type = "error", step = step, error = model_err })
            Ui.toast("Model error")
            return true, false, model_err
        end

        action, parse_err, repaired_text = Parser.parse_action_checked(CONFIG, call_text_model, model_text)
        if not parse_err then
            action = Memory.sanitize_action(action)
            local search_reason = search_exploration_reason(CONFIG, memory, model_text, action)
            local bad_action_reason = nil
            if not search_reason then
                bad_action_reason = Memory.detect_bad_action_reuse(CONFIG, memory, action)
            end
            local early_info_reason = nil
            if not search_reason and not bad_action_reason then
                early_info_reason = premature_info_reason(CONFIG, memory, action)
            end
            local ineffective_action_reason = nil
            if not search_reason and not bad_action_reason and not early_info_reason then
                ineffective_action_reason = Memory.detect_ineffective_action_loop(CONFIG, memory, action)
            end
            if not search_reason and not bad_action_reason and not early_info_reason and not ineffective_action_reason then
                break
            end

            if search_reason then
                consecutive_search_exploration_count = consecutive_search_exploration_count + 1
                if consecutive_search_exploration_count > CONFIG.search_exploration_retry_count or model_call_index >= max_recovery_model_calls then
                    LCC.log(1, "模型过早得出找不到结论，改为继续探索：" .. tostring(search_reason))
                    action = fallback_search_slide_action(search_reason, CONFIG, memory)
                    repaired_text = nil
                    break
                end

                reset_recovery_counts("search_exploration")
                LCC.log(1, "模型搜索未穷尽就得出找不到结论，连续第 " .. tostring(consecutive_search_exploration_count) .. " 次，正在重问")
                Config.append_log(CONFIG, {
                    time = sys.mtime(),
                    type = "search_exploration_retry",
                    step = step,
                    retry = consecutive_search_exploration_count,
                    action = action,
                    reason = search_reason,
                    model_response = model_text,
                    repaired_response = repaired_text,
                })
                prepare_retry_frame(tostring(step) .. "_search_exploration_" .. tostring(consecutive_search_exploration_count), search_exploration_retry_instruction(search_reason, consecutive_search_exploration_count))
            elseif early_info_reason then
                consecutive_premature_info_count = consecutive_premature_info_count + 1
                if consecutive_premature_info_count > CONFIG.premature_info_retry_count or model_call_index >= max_recovery_model_calls then
                    LCC.log(1, "模型过早请求人工，改为继续滑动查找：" .. tostring(early_info_reason))
                    action = fallback_search_slide_action(early_info_reason, CONFIG, memory)
                    repaired_text = nil
                    break
                end

                reset_recovery_counts("premature_info")
                LCC.log(1, "模型过早请求人工，连续第 " .. tostring(consecutive_premature_info_count) .. " 次，正在重问")
                Config.append_log(CONFIG, {
                    time = sys.mtime(),
                    type = "premature_info_retry",
                    step = step,
                    retry = consecutive_premature_info_count,
                    action = action,
                    reason = early_info_reason,
                    model_response = model_text,
                    repaired_response = repaired_text,
                })
                prepare_retry_frame(tostring(step) .. "_premature_info_" .. tostring(consecutive_premature_info_count), premature_info_retry_instruction(early_info_reason, consecutive_premature_info_count))
            elseif bad_action_reason then
                consecutive_bad_action_count = consecutive_bad_action_count + 1
                if Parser.normalize_action_type(Parser.field(action, "action", "Action", "action_type", "type")) == "SLIDE" then
                    action = bad_action_retry_failed_action(CONFIG, memory, bad_action_reason, action, consecutive_bad_action_count)
                    if Parser.normalize_action_type(Parser.field(action, "action", "Action", "action_type", "type")) ~= "INFO" then
                        LCC.log(1, "候选滑动方向已被截图证明无效，直接改用保守恢复：" .. Memory.action_signature(action))
                        Config.append_log(CONFIG, {
                            time = sys.mtime(),
                            type = "bad_action_recovery",
                            step = step,
                            retry = consecutive_bad_action_count,
                            reason = bad_action_reason,
                            action = action,
                            model_response = model_text,
                            repaired_response = repaired_text,
                        })
                        repaired_text = nil
                        break
                    end
                end
                if consecutive_bad_action_count > CONFIG.bad_action_retry_count or model_call_index >= max_recovery_model_calls then
                    action = bad_action_retry_failed_action(CONFIG, memory, bad_action_reason, action, consecutive_bad_action_count)
                    if Parser.normalize_action_type(Parser.field(action, "action", "Action", "action_type", "type")) == "INFO" then
                        LCC.log(1, "模型连续 " .. tostring(consecutive_bad_action_count) .. " 次提出已知错误动作，转人工确认：" .. tostring(bad_action_reason))
                    else
                        LCC.log(1, "模型连续 " .. tostring(consecutive_bad_action_count) .. " 次提出已知错误动作，改用保守恢复：" .. Memory.action_signature(action))
                    end
                    repaired_text = nil
                    break
                end

                reset_recovery_counts("bad_action")
                LCC.log(1, "模型提出已知错误动作，连续第 " .. tostring(consecutive_bad_action_count) .. " 次，正在重问")
                Config.append_log(CONFIG, {
                    time = sys.mtime(),
                    type = "bad_action_retry",
                    step = step,
                    retry = consecutive_bad_action_count,
                    action = action,
                    reason = bad_action_reason,
                    model_response = model_text,
                    repaired_response = repaired_text,
                })
                prepare_retry_frame(tostring(step) .. "_bad_action_" .. tostring(consecutive_bad_action_count), bad_action_retry_instruction(bad_action_reason, action, consecutive_bad_action_count))
            else
                consecutive_ineffective_action_count = consecutive_ineffective_action_count + 1
                if consecutive_ineffective_action_count > CONFIG.ineffective_action_retry_count or model_call_index >= max_recovery_model_calls then
                    LCC.log(1, "模型连续 " .. tostring(consecutive_ineffective_action_count) .. " 次提出无效循环动作，尝试保守恢复：" .. tostring(ineffective_action_reason))
                    action = ineffective_action_failed_action(CONFIG, memory, ineffective_action_reason, action, consecutive_ineffective_action_count)
                    repaired_text = nil
                    break
                end

                reset_recovery_counts("ineffective_action")
                LCC.log(1, "模型提出无效循环动作，连续第 " .. tostring(consecutive_ineffective_action_count) .. " 次，正在重问")
                Config.append_log(CONFIG, {
                    time = sys.mtime(),
                    type = "ineffective_action_retry",
                    step = step,
                    retry = consecutive_ineffective_action_count,
                    action = action,
                    reason = ineffective_action_reason,
                    model_response = model_text,
                    repaired_response = repaired_text,
                })
                prepare_retry_frame(tostring(step) .. "_ineffective_action_" .. tostring(consecutive_ineffective_action_count), ineffective_action_retry_instruction(ineffective_action_reason, action, consecutive_ineffective_action_count))
            end
        end
        local parse_search_reason = parse_err and search_exploration_reason(CONFIG, memory, model_text, nil) or nil
        if parse_search_reason then
            consecutive_search_exploration_count = consecutive_search_exploration_count + 1
            if consecutive_search_exploration_count > CONFIG.search_exploration_retry_count or model_call_index >= max_recovery_model_calls then
                LCC.log(1, "模型输出不可执行且过早得出找不到结论，改为继续探索：" .. tostring(parse_search_reason))
                action = fallback_search_slide_action(parse_search_reason, CONFIG, memory)
                repaired_text = nil
                break
            end

            reset_recovery_counts("search_exploration")
            LCC.log(1, "模型输出不可执行且搜索未穷尽，连续第 " .. tostring(consecutive_search_exploration_count) .. " 次，正在重问")
            Config.append_log(CONFIG, {
                time = sys.mtime(),
                type = "search_exploration_retry",
                step = step,
                retry = consecutive_search_exploration_count,
                error = parse_err,
                reason = parse_search_reason,
                model_response = model_text,
                repaired_response = repaired_text,
            })
            prepare_retry_frame(tostring(step) .. "_search_exploration_" .. tostring(consecutive_search_exploration_count), search_exploration_retry_instruction(parse_search_reason, consecutive_search_exploration_count))
        elseif parse_err and not Parser.is_coordinate_missing_error(parse_err) then
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

            reset_coordinate_retry_counts()
            LCC.log(1, "模型输出无法解析，连续第 " .. tostring(consecutive_parse_error_count) .. " 次，正在重问")
            Config.append_log(CONFIG, {
                time = sys.mtime(),
                type = "parse_retry",
                step = step,
                retry = consecutive_parse_error_count,
                context_reset = use_parse_reset_history,
                model_response = model_text,
                repaired_response = repaired_text,
                error = parse_err,
            })
            prepare_retry_frame(tostring(step) .. "_parse_" .. tostring(consecutive_parse_error_count), parse_retry_instruction(parse_err, model_text, consecutive_parse_error_count, use_parse_reset_history))
        elseif parse_err then
            local missing_action_type = Parser.coordinate_missing_action_type(parse_err) or "UNKNOWN"
            local partial_action = Parser.parse_action(model_text)
            local filled_action, autofill = Observation.autofill_point_action(observation, partial_action, model_text, missing_action_type)
            if filled_action and Parser.validate_action(filled_action) then
                action = filled_action
                repaired_text = nil
                LCC.log(1, "模型输出 " .. missing_action_type .. " 缺少坐标，已从当前可见元素“" .. tostring(autofill.target_text or "") .. "”自动补全：" .. tostring(autofill.point[1]) .. "," .. tostring(autofill.point[2]))
                Config.append_log(CONFIG, {
                    time = sys.mtime(),
                    type = "coordinate_autofill",
                    step = step,
                    missing_action_type = missing_action_type,
                    error = parse_err,
                    action = action,
                    autofill = autofill,
                    model_response = model_text,
                })
                break
            end
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
                time = sys.mtime(),
                type = "coordinate_retry",
                step = step,
                retry = total_coordinate_retries,
                missing_action_type = missing_action_type,
                consecutive_missing_count = consecutive_missing_count,
                error = parse_err,
                model_response = model_text,
            })
            prepare_retry_frame(tostring(step) .. "_coordinate_" .. tostring(total_coordinate_retries), coordinate_retry_instruction(parse_err, model_text, consecutive_missing_count, missing_action_type))
        end
    end
    end

    if not action then
        action = parse_retry_failed_action(parse_err or "模型恢复循环结束但没有可执行动作", math.max(consecutive_parse_error_count, consecutive_missing_count))
    end
    action = Memory.sanitize_action(action)

    local original_action = action
    local visible_target_action, visible_target = visible_navigation_target_action(CONFIG, action, observation)
    if visible_target_action and Parser.validate_action(visible_target_action) then
        action = visible_target_action
        LCC.log(1, "任务路径目标已可见，改为点击“" .. tostring(visible_target.text or "") .. "”：" .. tostring(visible_target.point[1]) .. "," .. tostring(visible_target.point[2]))
        Config.append_log(CONFIG, {
            time = sys.mtime(),
            type = "visible_target_guard",
            step = step,
            original_action = original_action,
            action = action,
            target = visible_target,
        })
    end

    local guard_reason = Memory.detect_repetition(CONFIG, memory, action)
    if guard_reason then
        action = make_guard_action(original_action, guard_reason)
        Config.append_log(CONFIG, {
            time = sys.mtime(),
            type = "guard",
            step = step,
            reason = guard_reason,
            original_action = original_action,
        })
    end

    local unrelated_click_reason = click_hits_unrelated_visible_text(CONFIG, action, observation)
    if unrelated_click_reason then
        local blocked_action = action
        action = fallback_search_slide_action(unrelated_click_reason, CONFIG, memory)
        LCC.log(1, "候选点击命中无关文本，改为滑动查找：" .. tostring(unrelated_click_reason))
        Config.append_log(CONFIG, {
            time = sys.mtime(),
            type = "guard",
            step = step,
            reason = unrelated_click_reason,
            original_action = blocked_action,
            recovery_action = action,
        })
    end

    local should_stop, execution
    if Parser.normalize_action_type(Parser.field(action, "action", "Action", "action_type", "type")) == "COMPLETE" and complete_needs_confirmation(memory) then
        should_stop = false
        execution = complete_confirmation_execution(action)
    else
        should_stop, execution = Executor.execute_action(CONFIG, LCC, action, image_data_url)
    end
    local record = {
        step = step,
        action = action,
        execution = execution,
        screenshot = screenshot_path,
    }

    memory.records[#memory.records + 1] = record
    append_step_log(step, model_text, repaired_text, screenshot_path, observation_meta, action, original_action, execution)

    if should_stop then
        notify_user(execution.message or execution.error or execution.reason or "Stopped")
        return true, not execution.error, execution
    end

    compress_if_needed(step, memory)
    sys.msleep(CONFIG.delay_after_action_ms)
    return false, true, nil
end

local function run_agent()
    local memory = Memory.new()
    memory.repeat_plan = Policy.task_repeat_plan(CONFIG)
    CONFIG.repeat_plan = memory.repeat_plan
    write_session_start()
    Ui.toast("Device Agent start: " .. CONFIG.task)

    for step = 1, CONFIG.max_steps do
        local stopped, ok, result = run_step(step, memory)
        if stopped then
            return ok, result
        end
    end

    local message = "达到最大步数：" .. tostring(CONFIG.max_steps)
    Config.append_log(CONFIG, { time = sys.mtime(), type = "stop", reason = "MAX_STEPS_REACHED", message = message })
    notify_user(message)
    return false, message
end

local ok, result = run_agent()
return { ok = ok, result = result, log = CONFIG.log_dir .. "/session.jsonl" }
