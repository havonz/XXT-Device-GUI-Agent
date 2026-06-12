local M = {}

function M.system_prompt()
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

function M.user_prompt(task, history)
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

local function post_chat(config, payload, timeout_seconds)
    local last_err = nil
    local attempts = config.model_retry_count + 1
    for attempt = 1, attempts do
        local ok, code, _, body = pcall(function()
            local headers = {
                ["Content-Type"] = "application/json",
            }
            if type(config.api_key) == "string" and config.api_key ~= "" then
                headers["Authorization"] = "Bearer " .. config.api_key
            end
            return http.post{
                url = config.model_url,
                timeout = timeout_seconds or config.request_timeout,
                headers = headers,
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

function M.call_text_model(config, text, max_tokens)
    local payload = {
        model = config.model,
        temperature = 0.1,
        top_p = 0.95,
        max_tokens = max_tokens or config.max_tokens,
        messages = {
            {
                role = "user",
                content = {
                    { type = "text", text = text },
                },
            },
        },
    }
    return post_chat(config, payload, config.request_timeout)
end

function M.call_model(config, image_data_url, history)
    local payload = {
        model = config.model,
        temperature = config.temperature,
        top_p = 0.95,
        max_tokens = config.max_tokens,
        messages = {
            {
                role = "user",
                content = {
                    { type = "text", text = M.system_prompt() },
                    { type = "text", text = M.user_prompt(config.task, history) },
                    { type = "image_url", image_url = { url = image_data_url } },
                    { type = "text", text = "在执行操作之前，请务必回顾历史操作记录和动作空间，先在 <THINK> 中思考，然后输出 verify/note/explain/action/key_process/summary。" },
                },
            },
        },
    }
    return post_chat(config, payload, config.request_timeout)
end

return M
