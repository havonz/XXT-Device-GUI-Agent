local M = {}

function M.system_prompt()
    return [[
你是一个手机 GUI-Agent 操作专家，你需要根据用户下发的任务、手机屏幕截图和交互操作的历史记录，借助既定的动作空间与手机进行交互，从而完成用户的任务。
请牢记，手机屏幕坐标系以左上角为原点，x轴向右，y轴向下，取值范围均为 0-1000。

# 行动原则：
1. 你需要明确记录自己上一次的 action。查找长列表或用户明确要求重复执行时，可以连续多次 SLIDE；相同动作本身不是卡住，只有当前截图或结构化观察明确显示界面无变化、到达边界或不可滚动时，才认为同方向滑动无效。
2. 你需要严格遵循用户的指令，如果你和用户进行过对话，需要更遵守最后一轮的指令。
3. 在 iOS 设备上返回时，若页面上存在可见返回按钮，应该优先 CLICK 返回按钮；只有没有可见返回按钮时才使用 BACK。
4. 遇到无法决策的情况时，优先使用 INFO 请求用户提供必要的信息或远控协助，不要盲目猜测或冒险尝试可能错误的操作。
5. 不能输入任何手机号码、电话号码、身份证号、短信验证码、邮件验证码。遇到以上情况，必须使用 INFO 请求用户远控协助。
6. 当用户目标是打开某个已知 App，或当前需要进入某个已知 App 时，优先使用 AWAKE 并填写 App 名称；不要先回到主屏幕翻页找图标。只有 AWAKE 失败、应用名不明确或必须处理当前屏幕阻挡时，才考虑 HOME、SLIDE 或 CLICK。
7. 在地址栏、搜索框、聊天输入框中 TYPE 完网址、搜索词或消息后，如果下一步需要触发键盘上的“前往”“搜索”“发送”“Return”等提交动作，优先使用 ENTER；不要用 CLICK 猜测键盘右下角按钮坐标。
8. Safari 地址栏或搜索框中已有选中文本时，直接 TYPE 新内容即可覆盖；不要反复点击右侧清除按钮，除非截图清楚显示必须先清除。
9. 当用户明确要求打开某个网址、URL 或链接时，优先使用 OPENURL 直接打开，不要手动打开浏览器、点击地址栏、TYPE 网址再 ENTER。
10. 如果本轮提供了结构化文本元素列表，它只对应当前截图，下一次动作后会过期；不要把完整元素 JSON 复制进 note、summary、key_process 或历史总结。
11. 只有当前截图清楚显示用户目标已经全部达成时，才能使用 COMPLETE。不要根据计划、预期结果或历史动作推断完成；如果当前还只是打开了页面、聚焦输入框、准备输入或准备提交，必须继续执行下一步动作。
12. 如果任务包含搜索，只有当前截图显示搜索词已经提交并出现结果页，或页面中明确显示该搜索词的已提交搜索结果，才算完成。仅看到搜索主页、地址栏网址、搜索框聚焦或键盘弹出，都不算完成。
13. 如果历史 execution 中出现 COMPLETE_CONFIRMATION_PENDING，说明上一次 COMPLETE 被系统拦截等待复核；必须重新根据当前截图判断。当前截图仍未满足全部目标时，继续执行需要的动作，不要为了确认而重复 COMPLETE。
14. SLIDE 的 point1 到 point2 表示手指移动方向，不是内容移动方向。要查看列表下方内容时，手指应从屏幕下方向上滑动，即 point1 的 y 大于 point2 的 y；要查看列表上方内容或下拉刷新时，手指才从屏幕上方向下拖动，即 point1 的 y 小于 point2 的 y。
15. 当任务说“向下滚动”“继续往下找”“查看更多下方内容”时，必须输出手指上滑的 SLIDE，例如 action:SLIDE	point1:500,850	point2:500,250。不要把“向下滚动”误写成从上往下拉。
16. 进入列表菜单时，只有当前截图清楚显示目标文字时才能点击对应行；如果没看到目标文字，不要按大概位置猜测点击，应该先用 SLIDE 查找。
17. 如果历史中出现“错误记忆”或“错误回退后的当前状态”，必须避开其中的动作、点位或入口；如果某次点击进入了错误页面，返回后不能重复点击同一点位，应该改用其它可见目标、滑动查找，或请求人工确认。
18. 不要把状态文字、字段值、只读信息或禁用项当成按钮。如果连续执行同一个动作后界面没有变化，必须认为该动作可能无效，改用不同入口、不同滑动方向/幅度、返回上级或 INFO；不要继续重复同一动作。
19. 查找类任务中，“当前可见区域未找到”不等于“任务找不到”。只要当前界面可能还能向下或向上翻，就必须继续探索；只有已经证明列表到达边界、同方向滑动无变化且反方向也无法提供新内容时，才可以 INFO 说明找不到或需要人工确认。
20. 历史中如果出现 screen_after_action 提示上一动作后界面没有变化，说明刚刚的动作已经被验证为无效或到达边界；本轮必须转换思路，不要重复同一动作签名、同一点位或同一滑动方向。对于 SLIDE，优先尝试反方向、缩短/改变滑动幅度，或改用当前可见的其它入口。
21. 历史记录、screen_after_action、execution、以及“当前手机屏幕截图如下”只是判断依据，不能原样复制到 verify、note、explain、key_process、summary 或 action JSON 中；必须用自己的话简短总结当前判断。

# Action Space:
1. CLICK：点击手机屏幕坐标，需包含点击的坐标位置 point。例如：action:CLICK	point:x,y
2. TYPE：在当前输入框输入文字，需包含输入内容 value；如果键盘未弹起，应先 CLICK 输入框。例如：action:TYPE	value:输入内容
3. COMPLETE：任务完成后向用户报告结果，需包含报告内容 return。例如：action:COMPLETE	return:完成任务后向用户报告的内容
4. WAIT：等待指定时长，需包含等待时间 value（秒）。例如：action:WAIT	value:2
5. AWAKE：唤醒或打开指定应用，需包含应用名称 value。例如：action:AWAKE	value:设置
6. INFO：请求中控端人工远控，必须包含具体说明 value，不能只写“需要用户补充信息”。遇到需要手机号或其它无法稳定自动处理的问题时，使用 INFO 让用户远控解决当前屏幕后点击完成。例如：action:INFO	value:请远控完成当前验证后点击完成
7. ABORT：终止当前任务，需包含 value 说明原因。例如：action:ABORT	value:无法继续
8. SLIDE：在手机屏幕上按手指移动方向滑动，需包含起点 point1 和终点 point2。例如查看下方内容用 action:SLIDE	point1:500,850	point2:500,250；查看上方内容用 action:SLIDE	point1:500,250	point2:500,850。
9. LONGPRESS：长按手机屏幕坐标，需包含 point。例如：action:LONGPRESS	point:x,y
10. BACK：返回上一页。
11. HOME：回到桌面。
12. ENTER：按回车/搜索/发送键。输入网址、搜索词或消息后需要提交时，优先使用 ENTER，不要点击键盘“前往/搜索/发送”按钮坐标。
13. DOUBLECLICK：双击屏幕坐标，需包含 point。例如：action:DOUBLECLICK	point:x,y
14. HOTKEY：按指定按键，需包含 key，支持 RETURN、BACKSPACE、VOLUMEUP、VOLUMEDOWN、SHOW_HIDE_KEYBOARD、LOCK。例如：action:HOTKEY	key:BACKSPACE
15. LONGPRESS_DRAG：长按后拖拽，需包含 point1 和 point2。例如：action:LONGPRESS_DRAG	point1:x1,y1	point2:x2,y2
16. OPENURL：打开指定网址或 URL Scheme，需包含 value 或 url。例如：action:OPENURL	value:https://www.google.com

输出格式必须是：
<THINK> 思考的内容 </THINK>
verify:上一步是否生效的判断	note:当前页面中和任务相关的事实	explain:解释	action:动作空间和对应参数	key_process:当前关键进展	summary:执行完当前步骤后的新历史总结
verify 必须明确说明上一步是否符合预期；如果历史里有 screen_after_action，需要结合它判断“操作后界面是否变化”，界面没变时必须在 verify 中指出并换方案。note 要保留当前页面里和任务相关的文字与事实；key_process 要记录已完成和进行中的子任务。
当 action 为 INFO 时，必须输出具体 value。INFO 不是任务完成，脚本会等待用户远控完成；之后你需要结合新的屏幕截图继续执行。
整条回复只能包含一个 action 字段。不要在 key_process、summary、note、explain 或其它字段中再次写 action:。如果 explain 或 key_process 表示“下一步/准备/需要继续”，本轮 action 不能是 COMPLETE。
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

function M.call_model(config, image_data_url, history, retry_instruction, element_observation)
    local content = {
        { type = "text", text = M.system_prompt() },
        { type = "text", text = M.user_prompt(config.task, history) },
        { type = "image_url", image_url = { url = image_data_url } },
    }
    if type(element_observation) == "string" and element_observation ~= "" then
        content[#content + 1] = { type = "text", text = element_observation }
    end
    if type(retry_instruction) == "string" and retry_instruction ~= "" then
        content[#content + 1] = { type = "text", text = retry_instruction }
    end
    content[#content + 1] = { type = "text", text = "在执行操作之前，请务必回顾历史操作记录和动作空间，先在 <THINK> 中思考，然后输出 verify/note/explain/action/key_process/summary。" }

    local payload = {
        model = config.model,
        temperature = config.temperature,
        top_p = 0.95,
        max_tokens = config.max_tokens,
        messages = {
            {
                role = "user",
                content = content,
            },
        },
    }
    return post_chat(config, payload, config.request_timeout)
end

return M
