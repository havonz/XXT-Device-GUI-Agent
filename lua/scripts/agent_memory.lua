local Parser = require("agent_parser")
local Policy = require("agent_task_policy")

local M = {}

local CLICK_LOOP_ACTIONS = {
    CLICK = true,
    DOUBLECLICK = true,
}

local SLIDE_LOOP_ACTIONS = {
    SLIDE = true,
}

local LOOP_GUARD_EXEMPT_ACTIONS = {
    COMPLETE = true,
    INFO = true,
    ABORT = true,
}

local BAD_MEMORY_EXEMPT_ACTIONS = {
    COMPLETE = true,
    INFO = true,
    ABORT = true,
}

local HARD_FAILURE_PATTERNS = {
    "未执行有效动作",
    "操作错误",
    "错误地进入",
    "进入错误",
    "误入",
    "误点击",
    "不正确",
    "仍停留",
    "没有变化",
    "无变化",
    "没有反应",
    "没反应",
    "无效",
    "不可点击",
    "不能点击",
    "无法点击",
    "不能滑动",
    "无法滑动",
    "不可滚动",
    "无法滚动",
    "需要先返回",
    "需要点击返回",
    "回到主设置",
    "返回主设置",
    "wrong",
    "failed",
    "incorrect",
    "not expected",
}

local GENERAL_FAILURE_PATTERNS = {
    "未达到预期",
    "未成功",
    "没有成功",
}

local PREVIOUS_ACTION_FAILURE_PATTERNS = {
    "错误地进入",
    "进入错误",
    "进错",
    "误入",
    "误点击",
    "点错",
    "操作错误",
    "需要先返回",
    "需要点击返回",
    "需要返回",
    "返回上级",
    "返回上一页",
    "回到主设置",
    "返回主设置",
    "wrong page",
    "wrong screen",
    "incorrect page",
    "misclick",
    "mis-click",
}

local bad_action_entries
local recovery_hint_lines
local repetition_warning_lines

function M.new()
    return {
        records = {},
        compressed_state = "",
    }
end

local function repetition_guard_mode(config)
    local mode = type(config) == "table" and config.repetition_guard_mode or nil
    if mode == "off" or mode == "warn" or mode == "block" then
        return mode
    end
    if type(config) == "table" and config.enable_repetition_guard == true then
        return "block"
    end
    return "off"
end

local function repetition_guard_blocks(config)
    return repetition_guard_mode(config) == "block"
end

local function repetition_guard_warns(config)
    return repetition_guard_mode(config) == "warn"
end

function M.repetition_guard_mode(config)
    return repetition_guard_mode(config)
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

local function clean_history_text(text)
    text = tostring(text or "")
    if text == "" then
        return text
    end
    local kept = {}
    local markers = {
        "action:",
        "action：",
        "Action:",
        "Action：",
        "建议操作",
        "建议下一步",
        "推荐操作",
        "下一步操作",
        "screen_after_action:",
        "execution:",
        "execution_result:",
        "当前手机屏幕截图如下",
        "已知用户指令为",
        "已知已经执行过的历史动作如下",
    }
    for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
        for _, marker in ipairs(markers) do
            local start_pos = string.find(line, marker, 1, true)
            if start_pos then
                line = string.sub(line, 1, start_pos - 1)
                break
            end
        end
        line = string.gsub(line, "%s+$", "")
        if line ~= "" then
            kept[#kept + 1] = line
        end
    end
    local cleaned = table.concat(kept, "\n")
    cleaned = string.gsub(cleaned, "\n+$", "")
    return cleaned
end

local function text_field(action, key)
    local value = action and action[key]
    if value == nil then
        return "none"
    end
    value = clean_history_text(value)
    if value == "" then
        return "none"
    end
    return limit_text(value, 800)
end

local function clean_compressed_state_text(text)
    text = clean_history_text(text)
    if text == "" then
        return ""
    end
    local kept = {}
    local drop_patterns = {
        "建议操作",
        "建议下一步",
        "推荐操作",
        "下一步操作",
        "继续向下滚动",
        "继续向上滚动",
        "继续同方向",
        "应继续向下",
        "应继续向上",
    }
    for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
        local drop = false
        for _, pattern in ipairs(drop_patterns) do
            if string.find(line, pattern, 1, true) then
                drop = true
                break
            end
        end
        if not drop then
            kept[#kept + 1] = line
        end
    end
    return string.gsub(table.concat(kept, "\n"), "\n+$", "")
end

local function record_is_complete_confirmation_pending(record)
    return type(record) == "table"
        and type(record.execution) == "table"
        and record.execution.reason == "COMPLETE_CONFIRMATION_PENDING"
end

local function screen_change_text(change, record)
    if type(change) ~= "table" then
        return nil
    end
    if record_is_complete_confirmation_pending(record) then
        return nil
    end
    if change.status == "changed" then
        return "上一动作执行后，当前截图与动作前截图相比，主内容已有变化。"
    end
    if change.status == "unchanged" then
        return "上一动作执行后，当前截图与动作前截图相比，主内容没有变化；这通常表示点击无效、滑动方向到达边界，或当前页面不支持该动作。"
    end
    if change.status == "unknown" and type(change.reason) == "string" and change.reason ~= "" then
        return "上一动作后的截图变化无法自动判断：" .. limit_text(change.reason, 120)
    end
    return nil
end

local function sanitized_action(action)
    if type(action) ~= "table" then
        return {}
    end
    local result = {}
    for key, value in pairs(action) do
        if type(value) == "string" then
            result[key] = limit_text(clean_history_text(value), 800)
        else
            result[key] = value
        end
    end
    return result
end

function M.sanitize_action(action)
    return sanitized_action(action)
end

local function assist_user_input_line(execution)
    if type(execution) ~= "table" or type(execution.assist_user_input_text) ~= "string" then
        return nil
    end
    local text = limit_text(execution.assist_user_input_text, 800)
    if text == "" then
        return nil
    end
    return "assist_user_input: 用户手动提交了以下内容，应作为下一步行动依据：" .. text
end

local function execution_result_line(execution)
    if type(execution) ~= "table" then
        return nil
    end
    if execution.error then
        return "execution_result: failed, " .. limit_text(execution.error, 180)
    end
    if execution.reason == "COMPLETE_CONFIRMATION_PENDING" then
        return "execution_result: complete pending, waiting for next frame confirmation"
    end
    if execution.done then
        return "execution_result: done, " .. limit_text(execution.message or execution.reason or "complete", 180)
    end
    local executed = execution.executed
    if type(executed) ~= "string" or executed == "" then
        return nil
    end
    if executed == "tap" or executed == "double_tap" or executed == "long_press" then
        return "execution_result: " .. executed .. " executed"
    end
    if executed == "slide" or executed == "long_press_drag" then
        return "execution_result: " .. executed .. " executed"
    end
    if executed == "type" then
        return "execution_result: type, input_ok=" .. tostring(execution.input_ok)
    end
    return "execution_result: " .. limit_text(executed, 180)
end

local function point_text(point)
    local x, y = Parser.point_value(point)
    if not x or not y then
        return "坐标未知"
    end
    return tostring(x) .. "," .. tostring(y)
end

local function operation_text(action)
    local action_type = Parser.normalize_action_type(Parser.field(action, "action", "Action", "action_type", "type"))
    if action_type == "" then
        return "none"
    end
    if action_type == "CLICK" then
        return "点击 " .. point_text(Parser.field(action, "point", "Point"))
    end
    if action_type == "DOUBLECLICK" then
        return "双击 " .. point_text(Parser.field(action, "point", "Point"))
    end
    if action_type == "LONGPRESS" then
        return "长按 " .. point_text(Parser.field(action, "point", "Point"))
    end
    if action_type == "SLIDE" then
        return "滑动 " .. point_text(Parser.field(action, "point1", "Point1")) .. " -> " .. point_text(Parser.field(action, "point2", "Point2"))
    end
    if action_type == "LONGPRESS_DRAG" then
        return "长按拖拽 " .. point_text(Parser.field(action, "point1", "Point1")) .. " -> " .. point_text(Parser.field(action, "point2", "Point2"))
    end
    local value = Parser.action_value(action) or Parser.field(action, "key", "Key")
    if value ~= nil and value ~= "" then
        return action_type .. " " .. tostring(value)
    end
    return action_type
end

function M.record_to_history(record)
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
        "operation: " .. operation_text(action),
        "key_process: " .. text_field(action, "key_process"),
        "summary: " .. text_field(action, "summary"),
    }
    local assist_line = assist_user_input_line(execution)
    if assist_line then
        lines[#lines + 1] = assist_line
    end
    local change_line = screen_change_text(record.screen_change, record)
    if change_line then
        lines[#lines + 1] = "screen_after_action: " .. change_line
    end
    local execution_line = execution_result_line(execution)
    if execution_line then
        lines[#lines + 1] = execution_line
    end
    return table.concat(lines, "\n")
end

function M.build_history(config, memory)
    if type(memory) ~= "table" then
        return "暂无历史操作"
    end
    local parts = {}
    if type(memory.compressed_state) == "string" and memory.compressed_state ~= "" then
        local compressed_state = clean_compressed_state_text(memory.compressed_state)
        if compressed_state ~= "" then
            parts[#parts + 1] = "以下是更早历史的压缩状态：\n" .. compressed_state
        end
    end

    local records = memory.records or {}
    local start_idx = #records - config.recent_history_steps + 1
    if start_idx < 1 then
        start_idx = 1
    end
    local bad_entries = bad_action_entries and bad_action_entries(config, records, start_idx)
    if bad_entries and #bad_entries > 0 then
        local bad_lines = {}
        for _, entry in ipairs(bad_entries) do
            bad_lines[#bad_lines + 1] = entry.line
        end
        parts[#parts + 1] = "错误记忆（后续决策必须避开这些动作）:\n" .. table.concat(bad_lines, "\n")
    end
    local recovery_lines = recovery_hint_lines and recovery_hint_lines(config, records)
    if recovery_lines and #recovery_lines > 0 then
        parts[#parts + 1] = "错误回退后的当前状态（本轮必须先遵守）:\n" .. table.concat(recovery_lines, "\n")
    end
    local repeat_lines = repetition_warning_lines and repetition_warning_lines(config, records)
    if repeat_lines and #repeat_lines > 0 then
        parts[#parts + 1] = "重复动作软提醒（不强制拦截）:\n" .. table.concat(repeat_lines, "\n")
    end
    for i = start_idx, #records do
        parts[#parts + 1] = M.record_to_history(records[i])
    end
    if #parts == 0 then
        return "暂无历史操作"
    end
    return table.concat(parts, "\n\n")
end

function M.compress(config, memory, call_text_model)
    if not config.enable_state_compression or type(memory) ~= "table" then
        return nil
    end
    local records = memory.records or {}
    local compress_count = #records - config.state_compression_recent_window
    if compress_count <= 0 then
        return nil
    end

    local old_parts = {}
    for i = 1, compress_count do
        old_parts[#old_parts + 1] = M.record_to_history(records[i])
    end
    local prompt = [[
你是设备端 GUI Agent 的历史状态压缩器。请把较早步骤压缩成一段稳定状态，供后续动作决策使用。

要求：
1. 只输出压缩状态，不要预测下一步动作。
2. 必须保留用户任务、已完成进展、重要页面事实、用户介入结果、未解决风险、当前子目标。
3. 必须保留已经被证明错误的动作或点位，例如“点击某坐标进入了错误页面，后续不要重复”。
4. 你压缩的是较早步骤，不要把较早步骤所在页面称为“当前页面”；当前页面以后续未压缩记录和最新截图为准。
5. 如果只是某个可见区域未找到目标，但流程仍在继续探索，不要压缩成“任务找不到”或“无法继续”。
6. 如果旧压缩状态与新增记录冲突，以新增记录为准。
7. 不要输出“建议操作”“建议下一步”“继续向下/向上”之类操作建议；当前方向必须由后续最新截图重新判断。
8. 如果多次同方向滑动未找到目标，只保留事实，例如“多次向下查找未找到”，不要把它压缩成“应继续同方向查找”。
9. 输出控制在 ]] .. tostring(config.state_compression_max_chars) .. [[ 字符以内。

旧压缩状态：
]] .. tostring(memory.compressed_state or "none") .. [[

新增较早步骤：
]] .. table.concat(old_parts, "\n\n")

    local compressed, err = call_text_model(prompt, math.min(config.max_tokens, 1200))
    if not compressed then
        return err
    end
    memory.compressed_state = limit_text(clean_compressed_state_text(compressed), config.state_compression_max_chars)
    local kept = {}
    for i = compress_count + 1, #records do
        kept[#kept + 1] = records[i]
    end
    memory.records = kept
    return nil
end

local function point_signature(point)
    local x, y = Parser.point_value(point)
    if not x or not y then
        return "nil"
    end
    x = math.floor(x / 10 + 0.5) * 10
    y = math.floor(y / 10 + 0.5) * 10
    return tostring(x) .. "," .. tostring(y)
end

function M.action_signature(action)
    local action_type = Parser.normalize_action_type(Parser.field(action, "action", "Action", "action_type", "type"))
    if Parser.is_point_action(action_type) then
        return action_type .. ":" .. point_signature(Parser.field(action, "point", "Point"))
    end
    if Parser.is_two_point_action(action_type) then
        return action_type .. ":" .. point_signature(Parser.field(action, "point1", "Point1")) .. ">" .. point_signature(Parser.field(action, "point2", "Point2"))
    end
    if Parser.uses_value_signature(action_type) then
        return action_type .. ":" .. tostring(Parser.action_value(action) or Parser.field(action, "key", "Key") or "")
    end
    return action_type
end

local function combined_feedback_text(record)
    local action = record and record.action
    if type(action) ~= "table" then
        return ""
    end
    local parts = {}
    for _, key in ipairs({ "verify", "note", "explain", "summary", "key_process" }) do
        local value = action[key]
        if type(value) == "string" and value ~= "" then
            local cleaned = clean_history_text(value)
            if cleaned ~= "" then
                parts[#parts + 1] = cleaned
            end
        end
    end
    local change_line = screen_change_text(record and record.screen_change, record)
    if change_line then
        parts[#parts + 1] = change_line
    end
    return table.concat(parts, " ")
end

local function shape_bbox(shape)
    if type(shape) ~= "table" then
        return nil
    end
    local min_x, min_y, max_x, max_y
    for _, point in ipairs(shape) do
        if type(point) == "table" then
            local x = tonumber(point.x)
            local y = tonumber(point.y)
            if x and y then
                min_x = min_x and math.min(min_x, x) or x
                min_y = min_y and math.min(min_y, y) or y
                max_x = max_x and math.max(max_x, x) or x
                max_y = max_y and math.max(max_y, y) or y
            end
        end
    end
    if not min_x or not min_y or not max_x or not max_y then
        return nil
    end
    return {
        x1 = min_x,
        y1 = min_y,
        x2 = max_x,
        y2 = max_y,
        w = math.max(1, max_x - min_x + 1),
        h = math.max(1, max_y - min_y + 1),
    }
end

local function bbox_area(box)
    if type(box) ~= "table" then
        return 0
    end
    return math.max(0, tonumber(box.w) or 0) * math.max(0, tonumber(box.h) or 0)
end

local function bbox_is_edge_noise(box, width, height)
    if type(box) ~= "table" or not width or not height then
        return true
    end
    if box.x1 >= width - 24 then
        return true
    end
    if box.y2 <= 60 then
        return true
    end
    if box.y1 >= height - 18 then
        return true
    end
    return false
end

local function destroy_image(img)
    if img then
        img:destroy()
    end
end

local function compare_screenshots(before_path, after_path)
    if type(before_path) ~= "string" or before_path == "" or type(after_path) ~= "string" or after_path == "" then
        return nil
    end
    if file.exists(before_path) ~= "file" or file.exists(after_path) ~= "file" then
        return { status = "unknown", reason = "screenshot file missing" }
    end
    local before = image.load_file(before_path)
    local after = image.load_file(after_path)
    if not before or not after then
        destroy_image(before)
        destroy_image(after)
        return { status = "unknown", reason = "load screenshot failed" }
    end
    local ok, shapes = pcall(function()
        return before:cv_compare_image(after, { should_visualize = false, approx_epsilon = 2 })
    end)
    local width, height = before:size()
    destroy_image(before)
    destroy_image(after)
    if not ok or type(shapes) ~= "table" then
        return { status = "unknown", reason = "compare screenshot failed" }
    end

    local total_area = 0
    local main_area = 0
    local main_shapes = 0
    for _, shape in ipairs(shapes) do
        local box = shape_bbox(shape)
        local area = bbox_area(box)
        total_area = total_area + area
        if area > 0 and not bbox_is_edge_noise(box, width, height) then
            main_area = main_area + area
            main_shapes = main_shapes + 1
        end
    end
    local screen_area = math.max(1, (tonumber(width) or 0) * (tonumber(height) or 0))
    local threshold = math.max(800, screen_area * 0.002)
    local status = "unchanged"
    if main_area >= threshold or main_shapes >= 3 then
        status = "changed"
    end
    return {
        status = status,
        shapes = #shapes,
        main_shapes = main_shapes,
        total_area = math.floor(total_area + 0.5),
        main_area = math.floor(main_area + 0.5),
        threshold = math.floor(threshold + 0.5),
    }
end

function M.compare_screenshots(before_path, after_path)
    return compare_screenshots(before_path, after_path)
end

local function action_type_of(action)
    return Parser.normalize_action_type(Parser.field(action, "action", "Action", "action_type", "type"))
end

local function action_exempt_from_loop_guard(action)
    return LOOP_GUARD_EXEMPT_ACTIONS[action_type_of(action)] == true
end

local function action_exempt_from_bad_memory(action)
    return BAD_MEMORY_EXEMPT_ACTIONS[action_type_of(action)] == true
end

local function action_is_repeat_task(action)
    return Parser.field(action, "auto_recovery", "Auto_recovery") == "repeat_task"
end

local function record_screen_changed(record)
    return type(record) == "table"
        and type(record.screen_change) == "table"
        and record.screen_change.status == "changed"
end

local function record_execution_failed(record)
    return type(record) == "table"
        and type(record.execution) == "table"
        and record.execution.error ~= nil
end

local function has_failure_signal(text)
    text = tostring(text or "")
    local lower = string.lower(text)
    for _, pattern in ipairs(HARD_FAILURE_PATTERNS) do
        if string.find(lower, string.lower(pattern), 1, true) then
            return true
        end
    end
    local has_general_failure = false
    for _, pattern in ipairs(GENERAL_FAILURE_PATTERNS) do
        if string.find(lower, string.lower(pattern), 1, true) then
            has_general_failure = true
            break
        end
    end
    if not has_general_failure then
        return false
    end

    local has_search_miss = Policy.has_search_miss(lower)
    local wants_continue = Policy.has_continue_search(lower)
    if has_search_miss and (wants_continue or not Policy.has_scroll_boundary(lower)) then
        return false
    end
    return true
end

local function has_previous_action_failure_signal(text)
    return Policy.text_contains_any(text, PREVIOUS_ACTION_FAILURE_PATTERNS)
end

local function repetition_threshold(config, action_type)
    local threshold = tonumber(config and config.same_action_loop_threshold) or 4
    if CLICK_LOOP_ACTIONS[action_type] then
        threshold = tonumber(config and config.click_loop_threshold) or threshold
    elseif SLIDE_LOOP_ACTIONS[action_type] then
        threshold = tonumber(config and config.slide_loop_threshold) or threshold
    end
    if threshold < 2 then
        threshold = 2
    end
    return threshold
end

local function consecutive_signature_count(records, signature)
    local same_count = 1
    for i = #(records or {}), 1, -1 do
        if M.action_signature(records[i].action) ~= signature then
            break
        end
        same_count = same_count + 1
    end
    return same_count
end

local function latest_same_signature_record(records, signature)
    local latest = records and records[#records]
    if not latest or M.action_signature(latest.action) ~= signature then
        return nil
    end
    return latest
end

local function repeated_slide_failure_reason(records, signature)
    local latest = latest_same_signature_record(records, signature)
    if not latest then
        return nil
    end
    local latest_feedback = combined_feedback_text(latest)
    if record_execution_failed(latest) then
        return "上一轮相同滑动执行失败。证据：" .. limit_text(latest_feedback, 180)
    end
    if type(latest.screen_change) == "table" and latest.screen_change.status == "unchanged" then
        return "上一轮相同滑动执行后截图主内容没有变化。证据：" .. limit_text(latest_feedback, 180)
    end
    if Policy.has_scroll_boundary(latest_feedback) then
        return "最近反馈显示相同滑动可能已到边界或界面无变化。证据：" .. limit_text(latest_feedback, 180)
    end
    return nil
end

repetition_warning_lines = function(config, records)
    if not repetition_guard_warns(config) or type(records) ~= "table" or #records < 1 then
        return nil
    end
    local latest = records[#records]
    local signature = M.action_signature(latest and latest.action)
    if signature == "" then
        return nil
    end
    local lines = {}
    local action_type = action_type_of(latest.action)
    if not action_exempt_from_loop_guard(latest.action) and not action_is_repeat_task(latest.action) then
        local same_count = consecutive_signature_count(records, signature) - 1
        local threshold = repetition_threshold(config, action_type)
        if same_count >= threshold then
            if action_type == "SLIDE" then
                local slide_reason = repeated_slide_failure_reason(records, signature)
                if slide_reason then
                    lines[#lines + 1] = "- 最近连续 " .. tostring(same_count) .. " 次执行 " .. signature .. "，且" .. slide_reason .. " 如果当前截图仍没有明显进展，应尝试其它方向、幅度、入口或请求人工确认。"
                end
            else
                lines[#lines + 1] = "- 最近连续 " .. tostring(same_count) .. " 次执行 " .. signature .. "。重复动作本身不一定错误；如果当前截图已经变化或用户明确要求重复，可以继续。若没有明显进展，应换目标、换策略或请求人工确认。"
            end
        end
    end

    local cycle_threshold = math.max(tonumber(config and config.action_cycle_threshold) or 3, 2)
    local required_count = cycle_threshold * 2
    if #records >= required_count then
        local signatures = {}
        for i = #records - required_count + 1, #records do
            signatures[#signatures + 1] = M.action_signature(records[i].action)
        end
        local a = signatures[#signatures - 1]
        local b = signatures[#signatures]
        if a ~= b then
            local matched = true
            for i = #signatures - 2, 1, -2 do
                if signatures[i] ~= b or signatures[i - 1] ~= a then
                    matched = false
                    break
                end
            end
            if matched then
                lines[#lines + 1] = "- 最近动作在 " .. a .. " 和 " .. b .. " 之间往返已达到 " .. tostring(cycle_threshold) .. " 轮。请先根据当前截图判断是否已经回到正确状态；如果没有，应换用新路径，不要继续机械往返。"
            end
        end
    end

    if #lines == 0 then
        return nil
    end
    return lines
end

function M.would_repeat_ineffective_action(config, memory, action)
    if not repetition_guard_blocks(config) then
        return false
    end
    local action_type = action_type_of(action)
    if action_exempt_from_loop_guard(action) then
        return false
    end
    local records = (memory and memory.records) or {}
    local signature = M.action_signature(action)
    local same_count = consecutive_signature_count(records, signature)
    if same_count < repetition_threshold(config, action_type) then
        return false
    end
    if action_type == "SLIDE" then
        return repeated_slide_failure_reason(records, signature) ~= nil
    end
    if action_is_repeat_task(action) then
        return false
    end
    return true
end

local function record_has_direct_failure(record)
    if type(record) ~= "table" then
        return false
    end
    if record_is_complete_confirmation_pending(record) or action_exempt_from_bad_memory(record.action) then
        return false
    end
    if type(record.screen_change) == "table" and record.screen_change.status == "unchanged" then
        return true
    end
    return record_execution_failed(record)
end

local function blamed_failure_record(records, index, feedback)
    local record = records[index]
    if record_has_direct_failure(record) then
        return record, index
    end
    local previous = records[index - 1]
    if type(previous) ~= "table" or action_exempt_from_bad_memory(previous.action) then
        return nil, nil
    end
    if record_screen_changed(previous) and not has_previous_action_failure_signal(feedback) then
        return nil, nil
    end
    return previous, index - 1
end

bad_action_entries = function(config, records, start_idx)
    local entries = {}
    local seen = {}
    local first = math.max(1, tonumber(start_idx) or 1)
    for i = first, #records do
        local record = records[i]
        if not record_is_complete_confirmation_pending(record) then
            local feedback = combined_feedback_text(record)
            if has_failure_signal(feedback) then
                local blamed, blamed_index = blamed_failure_record(records, i, feedback)
                if blamed and action_exempt_from_bad_memory(blamed.action) then
                    blamed = nil
                end
                if blamed then
                    local signature = M.action_signature(blamed.action)
                    if Policy.search_slide_can_continue(config, blamed.action, feedback) then
                        signature = nil
                    end
                    if signature and signature ~= "" and not seen[signature] then
                        seen[signature] = true
                        local evidence = limit_text(feedback, 220)
                        entries[#entries + 1] = {
                            signature = signature,
                            step = blamed.step or blamed_index,
                            evidence = evidence,
                            line = "- STEP " .. tostring(blamed.step or blamed_index) .. " 的动作 " .. signature .. " 被判定为错误或未达预期；不要重复该动作，除非当前截图明确显示它已成为正确目标。证据：" .. evidence,
                        }
                    end
                end
            end
        end
    end
    return entries
end

recovery_hint_lines = function(config, records)
    if type(records) ~= "table" or #records < 2 then
        return nil
    end
    local latest = records[#records]
    if record_is_complete_confirmation_pending(latest) then
        return nil
    end
    local feedback = combined_feedback_text(latest)
    if not has_failure_signal(feedback) then
        return nil
    end
    local failed, failed_index = blamed_failure_record(records, #records, feedback)
    local signature = M.action_signature(failed and failed.action)
    if not signature or signature == "" then
        return nil
    end
    if action_exempt_from_bad_memory(failed and failed.action) then
        return nil
    end
    if Policy.search_slide_can_continue(config, failed and failed.action, feedback) then
        return nil
    end
    if failed == latest then
        return {
            "- 最近 STEP " .. tostring(failed.step or failed_index) .. " 的动作 " .. signature .. " 已被当前截图变化判定为错误或未达预期。",
            "- 本轮禁止再次执行 " .. signature .. "；必须改用其它可见目标、改变滑动方向/幅度，或使用 INFO 请求人工确认。证据：" .. limit_text(feedback, 220),
        }
    end
    return {
        "- 上一轮已经判断 STEP " .. tostring(failed.step or failed_index) .. " 的动作 " .. signature .. " 导致错误页面或未达预期。",
        "- 最近 STEP " .. tostring(latest.step or #records) .. " 是纠正/回退动作；当前应在回退后的页面重新规划。",
        "- 本轮禁止再次执行 " .. signature .. "；必须改用其它可见目标、先 SLIDE 查找目标文字，或使用 INFO 请求人工确认。证据：" .. limit_text(feedback, 220),
    }
end

function M.detect_ineffective_action_loop(config, memory, action)
    if not repetition_guard_blocks(config) then
        return nil
    end
    local records = (memory and memory.records) or {}
    local signature = M.action_signature(action)
    if signature == "" then
        return nil
    end
    local action_type = action_type_of(action)
    if action_exempt_from_loop_guard(action) then
        return nil
    end
    if action_is_repeat_task(action) then
        return nil
    end
    local same_count = consecutive_signature_count(records, signature)
    local threshold = repetition_threshold(config, action_type)
    if same_count >= threshold then
        if action_type == "SLIDE" then
            local slide_reason = repeated_slide_failure_reason(records, signature)
            if slide_reason then
                return "候选滚动动作 " .. signature .. " 已连续 " .. tostring(same_count) .. " 次，且" .. slide_reason .. " 应换方向、缩短/改变滑动幅度、点击其它可见入口或请求人工确认。"
            end
            return nil
        end
        if action_is_repeat_task(action) then
            return nil
        end
        return "候选动作 " .. signature .. " 将形成连续 " .. tostring(same_count) .. " 次相同动作，达到阈值 " .. tostring(threshold) .. "。这通常表示前几次执行后页面没有有效变化；目标可能是状态文字、静态字段、禁用项，或当前页面不支持该方向滑动。"
    end

    local cycle_threshold = math.max(tonumber(config and config.action_cycle_threshold) or 3, 2)
    local required_count = cycle_threshold * 2
    if #records + 1 >= required_count then
        local signatures = {}
        for i = #records - required_count + 2, #records do
            signatures[#signatures + 1] = M.action_signature(records[i].action)
        end
        signatures[#signatures + 1] = signature

        local a = signatures[#signatures - 1]
        local b = signatures[#signatures]
        if a ~= b then
            local matched = true
            for i = #signatures - 2, 1, -2 do
                if signatures[i] ~= b or signatures[i - 1] ~= a then
                    matched = false
                    break
                end
            end
            if matched then
                return "候选动作会继续让动作在 " .. a .. " 和 " .. b .. " 之间来回循环，已达到 " .. tostring(cycle_threshold) .. " 轮。应换用新方案，不要继续在相同状态间往返。"
            end
        end
    end
    return nil
end

function M.detect_bad_action_reuse(config, memory, action)
    if action_exempt_from_bad_memory(action) then
        return nil
    end
    local records = (memory and memory.records) or {}
    if #records < 1 then
        return nil
    end
    local recent_steps = tonumber(config and config.recent_history_steps) or #records
    local start_idx = #records - recent_steps + 1
    if start_idx < 1 then
        start_idx = 1
    end
    local entries = bad_action_entries(config, records, start_idx)
    if not entries or #entries == 0 then
        return nil
    end
    local signature = M.action_signature(action)
    for _, entry in ipairs(entries) do
        if entry.signature == signature then
            return "候选动作 " .. signature .. " 已在 STEP " .. tostring(entry.step) .. " 被后续画面判定为错误或未达预期。证据：" .. entry.evidence .. "。请换用其它可见目标、滑动查找，或请求人工确认。"
        end
    end
    return nil
end

function M.detect_repetition(config, memory, action)
    if not repetition_guard_blocks(config) then
        return nil
    end
    if action_exempt_from_loop_guard(action) then
        return nil
    end
    if action_is_repeat_task(action) then
        return nil
    end
    local records = (memory and memory.records) or {}
    local signature = M.action_signature(action)
    local action_type = action_type_of(action)
    local same_count = consecutive_signature_count(records, signature)
    local threshold = repetition_threshold(config, action_type)

    if same_count >= threshold then
        if action_type == "SLIDE" then
            local slide_reason = repeated_slide_failure_reason(records, signature)
            if slide_reason then
                return "检测到重复滚动 " .. signature .. " 已达到 " .. tostring(same_count) .. " 次，且" .. slide_reason .. " 请换其它操作，不要继续重复同方向滑动。"
            end
            return nil
        end
        if action_is_repeat_task(action) then
            return nil
        end
        return "检测到连续重复动作 " .. signature .. " 已达到 " .. tostring(same_count) .. " 次。请远控确认当前页面状态，完成后点击完成。"
    end

    local cycle_threshold = math.max(tonumber(config.action_cycle_threshold) or 3, 2)
    local required_count = cycle_threshold * 2
    if #records + 1 >= required_count then
        local signatures = {}
        for i = #records - required_count + 2, #records do
            signatures[#signatures + 1] = M.action_signature(records[i].action)
        end
        signatures[#signatures + 1] = signature

        local a = signatures[#signatures - 1]
        local b = signatures[#signatures]
        if a ~= b then
            local matched = true
            for i = #signatures - 2, 1, -2 do
                if signatures[i] ~= b or signatures[i - 1] ~= a then
                    matched = false
                    break
                end
            end
            if matched then
                return "检测到动作在 " .. a .. " 和 " .. b .. " 之间来回循环已达到 " .. tostring(cycle_threshold) .. " 轮。请远控确认当前页面状态，完成后点击完成。"
            end
        end
    end
    return nil
end

return M
