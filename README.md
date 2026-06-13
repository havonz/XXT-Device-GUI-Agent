# XXT-Device-GUI-Agent

一个从 [stepfun-ai/gelab-zero](https://github.com/stepfun-ai/gelab-zero) 移植到 XXTouch 的设备端 GUI Agent。

它的使用方式很简单：用 VSCode 打开项目，连接 XXTLanControl，把项目打包成中控脚本包，然后在中控里启动。启动后会弹出配置界面，填好模型接口和任务内容就会开始执行。

## 演示视频

<video src="https://github.com/user-attachments/assets/542c7f64-3d59-4de5-b9ae-b56503daf632" controls width="100%"></video>


## 准备工作

你需要准备：

- 一台可运行 XXTouch 的 iOS 设备。
- VSCode，并安装 [XXTouch 扩展](vscode:extension/xxtouch.xxtouch)。
- 可访问设备的 [XXTLanControl](https://xxtlc-releases.xxtouch.app/) 中控。
- 一个 OpenAI Chat Completions 兼容的视觉模型接口。

模型可以使用 GELab-Zero 系列模型，也可以使用其它能识别手机截图并输出操作动作的多模态模型。
如果要在本地部署 GELab-Zero 模型，可以从 [gelab-zero-ollama-launcher Releases](https://github.com/havonz/gelab-zero-ollama-launcher/releases) 下载一键部署工具。

## 使用步骤

1. 从 [Releases](https://github.com/havonz/XXT-Device-GUI-Agent/releases) 下载最新的脚本包。
2. 如果使用本地 GELab-Zero 模型，先用 [一键部署工具](https://github.com/havonz/gelab-zero-ollama-launcher/releases) 部署模型服务。
3. 在电脑上打开 [XXTLanControl](https://xxtlc-releases.xxtouch.app/) 并把脚本包传入到 `文件管理` 中，双击安装这个脚本包。
4. 在 XXTLanControl 的 `脚本列表` 中选中这个脚本，选中设备，`运行脚本`。
5. 填写任务内容、模型接口 URL、模型名称和 API Key。本地模型部署完成后，把部署工具里显示的服务 URL 和模型名称填到这里。
6. 确认配置后开始运行。
7. 在中控日志或设备日志里查看执行过程和最终结果。

## 开发打包步骤

<video src="https://github.com/user-attachments/assets/c169e24e-120d-4f0c-b0a7-bddc22c92c92" controls width="100%"></video>

## 配置界面

启动时主要填写这几项：

| 配置项 | 说明 |
| --- | --- |
| `任务内容` | 你希望 Agent 完成的事情 |
| `模型接口 URL` | OpenAI Chat Completions 兼容接口地址 |
| `模型名称` | 请求里的 `model` 字段 |
| `API Key` | 模型接口鉴权信息，没有鉴权时按服务要求填写 |

常用调节项：

| 配置项 | 建议 |
| --- | --- |
| `模型温度` | 建议使用 `0.1`，输出更稳定 |
| `单次响应最大 Token` | 普通任务可用 `2048` |
| `最大步数` | 简单任务用 `20`，复杂任务按需提高 |
| `请求超时时间（秒）` | 本地模型较慢时适当调大 |
| `人工介入超时时间（秒）` | 需要远控协助时建议设为 `300` 秒以上 |
| `截图 JPEG 质量` | 默认 `55` 通常够用 |
| `动作后延迟毫秒数` | 默认 `1200`，页面慢时可调大 |
| `启用历史压缩` | 长任务建议开启 |
| `保存每步截图` | 排查问题时开启 |

## 任务写法

任务内容直接写自然语言即可，尽量明确目标和结束条件。

示例：

```text
打开设置-通用-关于本机-看看设备型号
```

```text
打开抖音签到
```

```text
打开设置，查看当前 Wi-Fi 名称，并告诉我结果
```

更稳定的写法：

- 说明要打开哪个 App。
- 说明最终要看到什么或完成什么。
- 如果只需要查询信息，要求它“看到后告诉我结果”。
- 如果遇到登录、验证码、手机号等情况，让它请求人工处理。

## 运行结果

任务完成后，Agent 会通过以下方式返回状态或结果：

- 设备 toast。
- 设备系统日志。
- XXTLanControl 日志频道 1。
- 中控人工远控任务提示。

如果模型判断任务完成，会输出完成结果；如果需要人工处理，会在中控里创建远控请求。

## 人工介入

遇到以下情况时，Agent 会暂停自动操作并请求人工远控：

- 需要输入手机号、身份证号、验证码等敏感信息。
- 当前页面模型无法可靠判断。
- 连续多次无法得到可执行动作。
- 连续重复操作，可能陷入循环。
- App 弹窗、登录态、权限提示等需要人工确认。

人工在中控里处理当前页面后，Agent 会继续根据新的屏幕状态执行后续步骤。

## 查看日志

中控里可以直接看运行日志。设备端也会保存每次运行的 session 日志：

```text
XXT_LOG_PATH/gelab-xxt-device-agent/<session_id>/session.jsonl
```

如果开启了 `保存每步截图`，截图会保存在：

```text
XXT_LOG_PATH/gelab-xxt-device-agent/<session_id>/screens/
```

排查问题时，优先看：

- 最后一条 `model_response`。
- 最后一条执行动作。
- 是否出现 `coordinate_retry`。
- 是否出现 `parse_retry`。
- 是否触发了人工介入。

## 常见问题

| 问题 | 处理方式 |
| --- | --- |
| 启动后没有配置界面 | 确认是从 XXTLanControl 中控启动脚本包 |
| 模型接口请求失败 | 确认设备能访问模型接口 URL |
| 一直输出格式错误 | 降低模型温度，换更稳定的视觉模型 |
| 一直缺坐标 | 查看截图是否清晰，必要时提高截图质量 |
| App 没有打开 | 确认设备已安装该 App，并检查任务里 App 名称是否明确 |
| 任务卡住 | 查看中控日志，必要时人工远控处理当前页面 |
| 结果不准 | 开启保存截图，复盘最后几步模型判断 |

## 注意事项

- 这个项目是设备端 Agent，不需要单独部署 MCP Server。
- 模型服务需要你自己准备，项目不包含模型权重。
- 任务越明确，执行越稳定。
- 不建议让 Agent 全自动处理验证码、登录验证、支付、身份信息填写等高风险流程。
- 复杂任务建议开启日志和截图，方便复盘。

## 致谢

本项目移植自 [stepfun-ai/gelab-zero](https://github.com/stepfun-ai/gelab-zero) 的 GUI Agent 思路。原项目采用 MIT License，模型、数据集和完整工程基础设施请以原仓库说明为准。
