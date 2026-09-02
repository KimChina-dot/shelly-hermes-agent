# PHASE 01 — 项目审计报告(V2.0 功能路线基线)

> 审计日期:2026-09-02 · 审计范围:`flutter/lib` `flutter/test` `flutter/android`
> 结论先行:**执行骨架(Shelly 文件域)与安全体系已达到可复用水位;Terminal/Git/Hermes/DSH 为零,按文档顺序补齐。**

## 一、现状总表

| 文档要求 | 现状 | 判定 | 对应代码 |
|---|---|---|---|
| **Agent:AgentCore 循环** | Execute/Observe 多轮循环 + 事件流 + 预算 + 取消 | ✅ 已完成,可复用 | `core/agent_core.dart` |
| **Agent:Planner** | 无独立 Planner,模型在循环内隐式规划 | ⚠️ 部分完成 | — |
| **Agent:Streaming** | SSE 流式 + ModelDelta 事件 + 打字机 | ✅ 已完成 | `core/gateway/sse.dart` |
| **Agent:Cancellation** | CancelFlag + TaskCoordinator.stop 优雅停机 | ✅ 已完成 | `agent_core.dart` `task_queue.dart` |
| **Tools:read/write/patch/search/list/exists** | 6 工具齐备,apply_patch 逐 hunk | ✅ 已完成 | `core/tools/registry.dart` `workspace.dart` |
| **Workspace:SAF/URI** | SAF 授权 + 持久化 URI + 路径解析读写 | ✅ 已完成 | `platform/platform_workspace.dart` + MainActivity |
| **Workspace:project state** | 无项目检测/快照/WorkspaceManager | ❌ 缺失 | — |
| **Safety:Approval** | ApprovalBroker 逐 hunk FIFO + 拒绝理由 | ✅ 已完成 | `core/approval_broker.dart` `diff_hunk_approval.dart` |
| **Safety:Risk/Policy** | 低/中/高 × 放行/确认/禁用,fail-closed | ✅ 已完成 | `core/tools/registry.dart` |
| **Safety:Audit** | JSONL 审计(启动/完成/审批事件) | ✅ 已完成 | `core/tools/audit.dart` |
| **Task:Queue/State/History** | 7 态状态机 + 并发 + 取消 + 历史 | ⚠️ 部分完成(文档要 9 态) | `core/task_queue.dart` |
| **Android:Service/Notification** | dataSync 前台服务 + 通知权限引导 + Dart 侧启停接线 | ✅ 已完成 | `platform/task_service.dart` + TaskForegroundService.kt |
| **Android:App 退出后继续** | 服务已占位,但引擎仍在主 isolate,进程被杀任务中断 | ❌ 缺失(PHASE 20) | — |
| **Gateway:OpenAI 兼容 SSE** | 抽象 Transport + 流式 + 工具映射 + 超时 | ✅ 已完成 | `core/gateway/openai_gateway.dart` |
| **Gateway:Model Discovery(/models)** | 无 | ❌ 缺失(PHASE 18) | — |
| **Checkpoint** | 每轮落盘 + 恢复重建(含工具卡) | ✅ 已完成 | `models.dart` + `state/chat_session.dart` |
| **Shelly:Terminal/Runtime** | 无 | ❌ 缺失(PHASE 04) | — |
| **Shelly:Git/Sandbox/Rollback** | 无 | ❌ 缺失(PHASE 05) | — |
| **Hermes:全部(账本/接入/append/Reflection/Forgetting)** | 无 | ❌ 缺失(PHASE 06–10) | — |
| **DSH:全部(Manifest/Registry/Tool/权限/安装/联动)** | 无;但 ToolSpec/ToolExecutor/ToolPolicy 已预留注册缝隙 | ❌ 缺失(PHASE 11–16) | — |
| **AgentProfile** | 无 | ❌ 缺失(PHASE 19) | — |
| **UI** | 1.0 精致 UI 已交付(五 Tab + 审批模态) | ✅ 超出文档"仅调试界面"预期;UI 2.0 重定义后置(PHASE 22) | `features/*` `design/*` |

## 二、与三系统架构的对应关系

- **Shelly(执行)**:文件域已就位(Workspace 抽象 + SAF 桥 + 6 工具 + 补丁);缺 Terminal、Git、Sandbox、项目检测。
- **Hermes(记忆)**:空白。存储约定(纯文本/JSONL,不引向量库)与文档一致,从零建即可。
- **DSH(能力)**:空白。但 `ToolSpec`/`ToolExecutor`/`ToolPolicy` 三件套就是天然的插件工具接入点,AgentCore 已经只依赖接口——符合"Core→Runtime Interface→Registry→Plugin"的要求,无需改核心。

## 三、冲突与建议修改

1. **引擎装配在 UI 层**:`_TaskRunner`(网关+注册表+审计+checkpoint 的组装)写在 `state/chat_session.dart`,违反分层 → **PHASE 02 下沉为 AgentRuntime**,UI 只传 AgentContext。
2. **TaskState 7 态 vs 文档 9 态**:`WAITING_APPROVAL` 目前只在 UI SessionPhase 表达 → PHASE 02 由 Runtime 上报,PHASE 21 统一扩展 `queued/waitingTool/paused/recovering`。
3. **Gateway 多 Provider**:接口已就位,`OpenAiCompatibleGateway` 天然覆盖 DeepSeek/Ollama/Custom → PHASE 18 只需加 `/models` 发现 + Provider 预设,不动核心。
4. **Android 真后台**:前台服务已可保活进程,但 Flutter 引擎任务循环在主 isolate;PHASE 20 需评估"Service 持有后台 engine + checkpoint 续跑"方案,先按文档保留 Checkpoint 语义。
5. **首页文案**:"你好,我是 Shelly" 与文档 Workbench 首页愿景不同 → PHASE 22 处理,现在不动。

## 四、复用决定

- AgentCore / ApprovalBroker / DiffHunk / TaskQueue / JsonlAuditLog / OpenAiGateway / SAF 桥:**直接复用,不改接口**。
- `_TaskRunner`:从 UI 层迁入 Runtime(逻辑保留,位置搬家)。
- 62 个既有测试作为回归底线。
