# 成熟 Agent 对标与 Luma 取舍

本文记录本轮能力升级前对主流 Agent 项目的观察结论。Luma 不复制外部实现，只吸收交互、架构和安全策略。

| 项目 | 重点学习 | Luma 的落地 | 未采用的原因 |
|---|---|---|---|
| Cline | Plan/Act 分离、工具审批、执行过程透明 | 主界面保留 Plan/Act 切换；低风险读取自动执行；写入类工具强制审批；工具开始/结束事件进入 UI 和 JSONL 日志 | 不复制 VS Code 插件宿主，Android 端继续走前台服务和 SAF 边界 |
| OpenHands | Event-sourced agent state 和任务恢复 | 会话事件用崩溃安全的 JSONL 记录；checkpoint v2 保存消息、assistant tool calls 和 pending tool calls；冷恢复优先走 durable checkpoint | 不把执行器放进浏览器/远端沙箱；v1 以本地设备为信任边界 |
| Aider | Diff-first 修改、上下文控制 | `apply_patch` 仍是文件修改主路径；多 hunk patch 会展开审批，批准的 hunk 可重组成新的 patch | 不引入仓库级索引和外部 lint/test 自动闭环，避免 Android 后台资源失控 |
| Continue | 多模型/Provider 抽象、清晰设置 | 继续使用 OpenAI-compatible chat completions；模型、endpoint、key 集中配置；请求层分离重试、取消和 SSE | 本轮不做多 Provider 插件矩阵，避免把 Android 包变成配置框架 |
| OpenAI Agents SDK | Guardrails、tracing、handoff | 保留 profile/team 编排；每次模型、审批、工具、状态转换都有 observer 事件；非幂等工具中断后重新请求用户决策 | 不开放任意 shell/process handoff，写入仍限定在 SAF 授权目录 |

## 本轮新增能力

- 模型响应通过 SSE 增量返回，UI 以 80ms 节流刷新并显示生成中光标。
- OpenAI tool call 分片按 index 聚合，完成后重组 id、name 和 arguments。
- SSE 响应已经开始后禁止自动重试，避免同一轮输出重复进入会话。
- 工具卡片显示开始、完成、失败和耗时；审批页可逐 hunk 决策。
- `AgentMessage` 原生携带 assistant tool calls；checkpoint v2 保存 pending tool call 阶段。
- 处于 `RUNNING` 的非幂等工具恢复时不会静默重跑，会重新请求用户决策。

## 安全取舍

Android v1 不提供任意进程、shell 或网络执行工具。文件读写只发生在用户明确授权的工作区 URI 内。低风险自动执行名单限制为 `read_file`、`exists`、`list_files`、`search_files`；所有修改类工具必须审批。
