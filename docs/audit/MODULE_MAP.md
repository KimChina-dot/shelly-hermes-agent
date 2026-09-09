# Shelly Hermes 模块地图(PHASE 0 审计 · 工作区 A)

> 基线 commit `5c46be2`(PHASE 54)。逐文件/逐目录盘点 `flutter/lib/`,每行给出:职责、关键类、provider/入口、依赖、稳定性、v3 处置。
> v3 处置口径(对齐 v3.0 主计划 facade-first 约定):**keep-as-is** = 原样保留;**wrap-with-facade** = 保留原地,新增 facade 导出收口访问;**move-later** = 3.1 再物理移动。
> 稳定性证据:测试文件 + `git log` 近期改动日期(2026-09 当前为 PHASE 44-54 迭代期)。

## 1. 入口层

| 路径 | 职责 | 关键类/符号 | Provider/入口 | 依赖 | 稳定性 | v3 处置 |
| --- | --- | --- | --- | --- | --- | --- |
| `lib/main.dart` | 进程入口:语义树暴露、crash 日志安装、ProviderScope 根 | `main()`、`_installCrashLogging()` | 应用唯一入口 | `app.dart`、`core/crash/crash_log_store.dart` | 稳定(29 行,PHASE 41 后未改) | keep-as-is |
| `lib/app.dart` | MaterialApp + 明暗主题 + web `?theme=` 支架 | `ShellyApp` | `themeModeProvider`(StateProvider) | `design/theme.dart`、`features/shell/home_shell.dart` | 稳定 | keep-as-is |

## 2. 核心层根文件(Agent 内核)

| 路径 | 职责 | 关键类/符号 | Provider/入口 | 依赖 | 稳定性 | v3 处置 |
| --- | --- | --- | --- | --- | --- | --- |
| `core/models.dart` | 引擎数据模型(1:1 移植 Kotlin AgentModels.kt) | `AgentMessage`、`ToolCall`、`ModelReply`、`AgentLimits(16/64k/32)`、`PendingToolCall`、`AgentCheckpoint`、`sealed AgentEvent` 家族、`ApprovalDecision` | 被所有层引用 | 仅 `dart:convert` | 稳定(`models_test.dart`;09-07) | keep-as-is |
| `core/agent_core.dart` | Agent 主循环:预算检查/压缩/逐 hunk 审批/断点恢复 | `AgentCore.run()`、`ModelGateway`、`StreamingModelGateway`、`ToolExecutor`、`ApprovalGateway`、`CheckpointStore`、`AgentObserver`、`ToolApprovalPolicy`、`AutoApproveReadOnlyPolicy`、`CancelFlag` | 无(被 runtime 调用) | models、approval_broker、gateway(仅 CachedTokensReply 类型)、context、diff_hunk_approval | 稳定(`agent_core_test.dart` 等 6 个测试文件;09-07) | keep-as-is |
| `core/approval_broker.dart` | 人工审批挂起 + 会话/持久 always-allow | `ApprovalBroker`、`PendingApproval`、`ApprovalGateway` | 无独立 provider;实例归 ChatSessionController(chat_session.dart:196) | models | 稳定(`approval_broker_test.dart`;09-09 小改) | keep-as-is |
| `core/task_queue.dart` | 多任务协调:并发槽、队列、暂停/恢复 | `TaskCoordinator`、`TaskState`(11 态)、`TaskStatus`、`AgentTaskRunner`、`AgentEventReporter` | 经 taskHistoryProvider 输出状态 | agent_core、models | 稳定(`task_queue_test.dart`、`task_states_test.dart`;09-03) | keep-as-is |
| `core/task_recovery.dart` | 进程被杀后的可恢复任务扫描 | `TaskRecoveryRecord`、`RecoveryCandidate`、`TaskRecoveryStore`、`TaskRecovery.scan()` | SettingsStore 实现其 Store 接口 | models、dart:convert | 稳定(`task_recovery_test.dart`) | keep-as-is |
| `core/agent_profile.dart` | 人格/限制预设 | `AgentProfile`、`agentProfilePresets` | settings_store 持久化;profile_page 编辑 | gateway/providers(仅 preset id 提示) | 稳定(`agent_profile_test.dart`;09-07) | keep-as-is |
| `core/diff_approval.dart` | 逐 hunk 审批 UI 模型 | `DiffHunk` | approval_sheet 渲染 | 无 | 稳定 | keep-as-is |
| `core/diff_hunk_approval.dart` | apply_patch ↔ 逐 hunk 拆分/重组 | `DiffHunkApproval.expand/collapse` | agent_core 循环内调用 | models、dart:convert | 稳定(`diff_hunk_approval_test.dart`) | keep-as-is |
| `core/error_messages.dart` | 异常 → 中文一句话 | `humanizeAgentError()` | chat/model_picker/profile 直接调用 | gateway(GatewayException) | 稳定(`error_messages_test.dart`) | keep-as-is |

## 3. 核心层能力目录

| 路径 | 职责 | 关键类/符号 | Provider/入口 | 依赖 | 稳定性 | v3 处置 |
| --- | --- | --- | --- | --- | --- | --- |
| `core/runtime/agent_runtime.dart` | 引擎组装:Hermes 回忆/记忆、策略与限制装配 | `AgentRuntime` | 由 ChatSessionController 持有(chat_session.dart:1396) | agent_core、approval_broker、models、tools/registry、agent_context | 稳定(`runtime_test.dart`) | wrap-with-facade(v3 Brain 需要走同一组装缝) |
| `core/runtime/agent_context.dart` | 运行时参数包 + 记忆接口 | `AgentContext`、`AgentMemoryAccess` | — | agent_core、models、tools/registry、workspace、gateway、context | 稳定 | keep-as-is |
| `core/runtime/tool_registry.dart` | 工具注册表缝 + 组合分发 | `AgentToolRegistry`、`CompositeToolRegistry`(先声明者赢) | — | agent_core、models、tools/registry | 稳定(runtime_test) | keep-as-is |
| `core/runtime/hardened_tool_executor.dart` | 工具执行护栏:120s 超时、20k 截断、模型摘要 | `HardenedToolExecutor` | — | models、tools/registry | 稳定 | keep-as-is |
| `core/tools/workspace.dart` | 工作区存储抽象 + 内存实现 + 工具集 | `Workspace`、`MemoryWorkspace`、`WorkspaceToolRegistry`、`decodeArguments` | `workspaceProvider`(chat_session.dart:1565)经 platform 工厂注入 | 无(纯 Dart) | 稳定(`tools_test.dart`) | keep-as-is |
| `core/tools/registry.dart` | 工具规格 + 信任策略 | `ToolSpec`、`ToolError`、`ToolPolicy(standard)`、`CompositeToolRegistry` 前置 | — | agent_core、models、runtime/tool_registry、workspace | 稳定 | keep-as-is |
| `core/tools/notes_tool.dart` | plan/notes 朗诵状态工具(PHASE 46) | `NotesToolRegistry` | 每次 run 新建(chat_session.dart:1202) | runtime/tool_registry、tools/registry | 稳定(`notes_tool_test.dart`) | keep-as-is |
| `core/tools/terminal_tools.dart` | fd/rg 结构化搜索 + 回退 | `TerminalSearchTools` | CompositeToolRegistry 成员 | shell/ShellExecutor 经构造注入 runner | 稳定(`terminal_tools_test.dart`) | keep-as-is |
| `core/tools/memory_search_tool.dart` | `search_memory` 自诊断工具(PHASE 43/52) | `MemorySearchToolRegistry` | CompositeToolRegistry 成员 | crash、memory、models、runtime、tools;**反向:state/settings_store.dart(ConversationSummary)** | 稳定(`memory_search_tool_test.dart`) | wrap-with-facade(先切断 core→state 反向依赖,把 ConversationSummary 定义下沉或注入) |
| `core/tools/audit.dart` | 工具活动 JSONL 审计 | `AuditSink`、`InMemoryAuditSink`、`JsonlAuditLog`(AgentObserver) | 可选挂 observer | agent_core、models | 稳定 | keep-as-is |
| `core/shell/shell_executor.dart` | Shell 策略/风险分类/执行/工具/审批策略 | `ShellPolicy`、`ShellRiskClassifier`、`ShellExecutor`、`ShellToolRegistry`、`ShellApprovalPolicy`、`ProcessRunner` 接口 | CompositeToolRegistry 成员 | agent_core、models、runtime、tools(workspace decodeArguments);runner 来自 platform | 稳定(`shell_test.dart`;09-02) | keep-as-is |
| `core/gateway/openai_gateway.dart` | OpenAI 兼容网关(流式、KV-cache、body 装饰器) | `OpenAiCompatibleGateway`、`ChatTransport`、`HttpChatTransport`、`GatewayException`、`CachedTokensReply` | `chatGatewayOverrideProvider` 测试缝;由 _TaskRunner 按 ModelConfig 构建 | agent_core(models)、openai_messages、sse、http | 变化中(PHASE 46A/51 触及;09-09) | wrap-with-facade(v3 Brain 调用必须计入 64K 预算,facade 处统一挂预算钩子) |
| `core/gateway/openai_messages.dart` | 请求/响应编码 | 消息编码函数 | — | models | 稳定 | keep-as-is |
| `core/gateway/sse.dart` | SSE 解析 | `SseParser` | — | 无 | 稳定(gateway_test) | keep-as-is |
| `core/gateway/providers.dart` | 内置 provider 预设 | `LlmProviderPreset`、`llmProviderPresets` | profile/model_picker 页 UI 数据 | 无 | 稳定 | keep-as-is |
| `core/gateway/model_discovery.dart` | `/v1/models` 拉取 | `ModelDiscovery`、`RemoteModel`、`ModelsTransport` | settings_store 拉模型列表 | http | 稳定(`model_discovery_test.dart`) | keep-as-is |
| `core/gateway/context_window.dart` | 模型上下文窗估算 | 估算函数 | settings_store/compactor 使用 | 无 | 稳定 | keep-as-is |
| `core/gateway/web_search.dart` | web 搜索请求改写装饰器 | `webSearchBodyDecorator` | 网关 bodyDecorator 链 | openai_gateway | 稳定(`web_search_test.dart`) | keep-as-is |
| `core/memory/memory_store.dart` | 分层事实存储(PHASE 52) | `MemoryFact`、`MemoryStore`、`ImportReport` | `memoryStoreProvider` | shared_preferences | 变化中(PHASE 47/50/52;`chat_memory/memory_store/memory_backup_test.dart`) | keep-as-is |
| `core/memory/memory_extractor.dart` | 会话结束自动抽取事实 | `MemoryExtractor` | observer 侧使用(chat_session.dart:1382) | gateway | 变化中(`memory_extractor_test.dart`) | keep-as-is |
| `core/memory/consolidation.dart` | 睡眠时合并/老化 | `MemoryConsolidator`、`ConsolidationReport` | MemoryMaintenanceService 调用 | memory_store | 变化中(`consolidation_test.dart`) | keep-as-is |
| `core/hermes/knowledge.dart` | 知识条目模型 | `KnowledgeEntry`、`KnowledgeVitality`、`estimateTokens` | — | 无 | 稳定(`hermes_test.dart`) | keep-as-is |
| `core/hermes/knowledge_store.dart` | 知识账本存取 | `HermesKnowledgeStore` | _TaskRunner/hermes_provider 构建 | tools/workspace、knowledge | 稳定 | keep-as-is |
| `core/hermes/knowledge_tool.dart` | append/recall 知识工具 | `KnowledgeToolRegistry` | CompositeToolRegistry 成员 | knowledge_store、runtime、tools | 稳定 | keep-as-is |
| `core/hermes/hermes_memory.dart` | 任务前回忆/任务后记忆 | `HermesMemory implements AgentMemoryAccess` | AgentContext.hermes(chat_session.dart:1406) | knowledge_store、runtime(AgentMemoryAccess)、forgetting | 稳定 | keep-as-is |
| `core/hermes/forgetting.dart` | 遗忘策略 | `ForgettingPolicy`、`ForgettingReport` | settings 注入 | 无 | 稳定 | keep-as-is |
| `core/hermes/reflection.dart` | 泛化/合并反思 | `Reflector`、`ReflectionReport` | hermes_provider 手动整理 | knowledge_store | 稳定 | keep-as-is |
| `core/hermes/memory_settings.dart` | 记忆设置模型 | `MemorySettings` | settings_store 持久化 | 无 | 稳定(`memory_settings_test.dart`) | keep-as-is |
| `core/context/context_compactor.dart` | 上下文压缩(PHASE 46B 可恢复) | `ContextCompactor`、`CompactionResult` | AgentContext.contextCompactor | gateway(摘要网关)、models | 稳定(`context_compactor_test.dart`;09-08) | keep-as-is |
| `core/mcp/mcp_client.dart` | MCP 客户端(HTTP/SSE) | `McpClient`、`McpServerConfig`、`McpToolInfo` | settings_store 存配置 | http、crypto | 稳定(`mcp_test.dart`) | keep-as-is |
| `core/mcp/mcp_tool_registry.dart` | MCP 工具表 | `McpToolRegistry` | _TaskRunner 接入(chat_session.dart:1238) | mcp_client、mcp_guard、runtime | 变化中(PHASE 48;`mcp_test.dart`) | keep-as-is |
| `core/mcp/mcp_guard.dart` | 供应链指纹守卫(PHASE 46A) | `McpGuard`、`McpGuardLedger`、`McpGuardReport` | 能力页展示 verdict | crypto、mcp_client | 变化中(`mcp_guard_test.dart`) | keep-as-is |
| `core/mcp/bridge_client.dart` | 桌面 sidecar 桥客户端(PHASE 45) | `BridgeToolRegistry` | _TaskRunner 接入(chat_session.dart:1254) | http、runtime | 稳定(`bridge_test.dart`) | keep-as-is |
| `core/mcp/bridge_server.dart` | stdio↔HTTP 桥服务(桌面侧) | `BridgeServer`、`BridgeConfig` | 桌面 host 启动 | dart:io | 稳定(`bridge_test.dart`;09-07) | keep-as-is |
| `core/mcp/bridge_dashboard.dart` | 桥调用仪表(PHASE 49) | `BridgeDashboard`、`BridgeCallLog` | 桌面 host | 无 | 稳定(`bridge_dashboard_test.dart`) | keep-as-is |
| `core/dsh/manifest.dart` | 插件清单/权限模型 | `DshManifest`、`DshPermissions`、`DshToolDecl` | installer 解析 | 无 | 稳定(`dsh_test.dart`;09-03) | keep-as-is |
| `core/dsh/plugin.dart` | 插件接口与宿主上下文 | `DshPlugin`、`DshHostContext`、`DshTool`、`ShellPlugin` | registry 注册 | tools/workspace(Workspace 视图) | 稳定 | keep-as-is |
| `core/dsh/registry.dart` | 插件注册表 | `DshPluginRegistry` | `dshRegistryProvider` | plugin、manifest | 稳定 | keep-as-is |
| `core/dsh/tool_registry.dart` | 插件工具表 + 信任策略 | `DshToolRegistry`、`DshTrustPolicy`、`DshTrust` | `dshToolsProvider` | runtime、registry | 稳定 | keep-as-is |
| `core/dsh/installer.dart` | 插件安装流程 | `DshInstaller` | 能力页调用 | manifest、registry、platform process_runner | 稳定 | keep-as-is |
| `core/dsh/hermes_bridge.dart` | 插件 ↔ Hermes 账本桥 | `DshHermesBridge` | 可选 | hermes | 稳定 | keep-as-is |
| `core/workspace/workspace_manager.dart` | 项目检测/快照/根持久化 | `WorkspaceManager`、`WorkspaceSnapshot(Diff)`、`WorkspaceStateStore` | `workspaceManagerProvider` | tools/workspace、project | 稳定(`workspace_project_test.dart`) | keep-as-is |
| `core/workspace/project.dart` | 项目识别 | `ProjectDetector`、`ProjectInfo` | manager 内部 | 无 | 稳定 | keep-as-is |
| `core/git/git_manager.dart` | git 状态/操作 | `GitManager`、`GitStatus` | 能力页/任务流可用 | platform process_runner | 稳定(`git_test.dart`;09-02) | keep-as-is |
| `core/git/git_sandbox.dart` | git 沙箱回滚 | `GitSandbox`、`SandboxSession`、`RollbackReport` | GitManager 协作 | git_manager、workspace | 稳定 | keep-as-is |
| `core/lan/lan_companion_server.dart` | LAN 伴生 HTTP 服务(PHASE 42) | `LanCompanionServer` | `lanCompanionProvider` 启停 | dart:io | 稳定(`lan_companion_server_test.dart`、`lan_companion_store_test.dart`) | keep-as-is |
| `core/tts/tts_service.dart` | 朗读服务 | `TtsService`、`FlutterTtsService` | chat_page 直接使用 | flutter_tts | 稳定(`tts_service_test.dart`) | keep-as-is |
| `core/platform/background_tasks.dart` | 后台任务唤醒桥(PHASE 45) | `BackgroundTaskBridge` | home_shell + scheduled_tasks | flutter/services | 稳定(`background_tasks_test.dart`;09-07) | keep-as-is |
| `core/platform/home_widget_bridge.dart` | 桌面小组件桥(PHASE 42) | `HomeWidgetBridge` | home_shell | flutter/services | 稳定(`home_widget_bridge_test.dart`) | keep-as-is |
| `core/crash/crash_log_store.dart` | 崩溃日志存取 | `CrashEntry`、`CrashLogStore`、`installCrashLogging` | main.dart 安装;memory_search/profile 读取 | shared_preferences | 稳定(`crash_log_store_test.dart`、`crash_logging_test.dart`) | keep-as-is |
| `core/diagnostics/environment_checker.dart` | 环境自检(fd/rg/node 等) | `EnvironmentChecker`、`EnvironmentCheck` | 能力页 | shell runner | 稳定(`environment_check_test.dart`) | keep-as-is |

## 4. 状态层(state/)

| 路径 | 职责 | 关键类/符号 | Provider | 依赖 | 稳定性 | v3 处置 |
| --- | --- | --- | --- | --- | --- | --- |
| `state/chat_session.dart` | 会话控制器 + 引擎装配(1633 行,状态层最大文件) | `ChatSessionController`、`ChatSessionState`、`ChatEntry` 族(User/Assistant/Tool/NoticeEntry)、`_TaskRunner`、`DemoModelGateway`、`_StoreCheckpoints`、`_SessionObserver` | `chatSessionProvider`、`workspaceProvider`、`workspaceAuthorizedProvider`、`workspaceManagerProvider`、`approvalQueueProvider`、`taskHistoryProvider`、`conversationImageStoreProvider`、`chatGatewayOverrideProvider`、`memoryStoreProvider` | core 26 个文件(全量清单见 DEPENDENCY_MAP §2)+ platform 4 个 + dsh/settings/usage | **易碎/最热**(PHASE 46B-54 每版必改,09-09;`chat_session_test.dart`、`regenerate_test.dart`、`session_management_test.dart`、`steering_test.dart`、`context_meter_test.dart`、`aux_model_test.dart` 兜底) | wrap-with-facade:v3 拆出"运行时装配工厂"(chat_session.dart:1163-1441 的 `_TaskRunner.run()`)与"会话 UI 状态"两块;facade 暴露 send/approve/steer |
| `state/settings_store.dart` | 全部 `shelly.*` 键读写中心(586 行) | `SettingsStore implements TaskRecoveryStore`、`ModelConfig`、`ConversationSummary`、`McpBridgeConfig`、`McpStdioServerConfig` | `settingsStoreProvider` | core/agent_profile、gateway/context_window、hermes/memory_settings、models、mcp/mcp_client、task_recovery、platform/secure_box | 稳定偏热(PHASE 51 加采样参数) | wrap-with-facade:v3 持久化迁移的收口点 |
| `state/scheduled_tasks.dart` | 定时任务存储/调度/心跳(523 行) | `ScheduledTask`、`ScheduledTaskStore`、`SchedulerService`、`SchedulerTicker` | `scheduledTaskStoreProvider`、`schedulerServiceProvider`、`scheduledTasksRevisionProvider` | core/platform/background_tasks、gateway、models、settings_store | 稳定(`scheduled_tasks_test.dart`;PHASE 41/45) | keep-as-is |
| `state/dsh_provider.dart` | DSH 三个 provider 组装(21 行) | — | `dshRegistryProvider`、`dshTrustProvider`、`dshToolsProvider` | core/dsh | 稳定 | keep-as-is |
| `state/hermes_provider.dart` | 记忆页账本快照 + 手动整理 | `HermesLedgerSnapshot`、`runUpkeepWith`、`UpkeepReport` | `hermesLedgerProvider`(autoDispose) | core/hermes 5 文件 + tools/workspace + chat_session + settings_store | 稳定 | keep-as-is |
| `state/lan_companion.dart` | LAN 开关/令牌/控制器 | `LanCompanionStore`、`LanCompanionState`、`LanCompanionController` | `lanCompanionProvider` | core/lan、models、settings_store、update_check | 稳定 | keep-as-is |
| `state/memory_maintenance.dart` | 日节流维护触发(PHASE 47) | `MemoryMaintenanceService` | 无(服务,由 shell 触发) | core/memory/consolidation、memory_store | 稳定(`memory_maintenance_test.dart`) | keep-as-is |
| `state/plugin_repo.dart` | 插件预设仓库 | `PluginPreset`、`PluginRepoStore` | `pluginRepoProvider` | shared_preferences | 稳定(`plugin_repo_test.dart`) | keep-as-is |
| `state/update_check.dart` | 版本检查(节流) | `UpdateCheckResult`、`UpdateCheckService` | `updateCheckProvider` | http、package_info_plus | 稳定(`update_check_test.dart`) | keep-as-is |
| `state/usage_stats.dart` | 用量统计(含 KV-cache 指标) | `UsageEntry`、`UsageTotals`、`UsageStatsStore` | `usageStatsProvider` | shared_preferences | 稳定(`usage_stats_test.dart`;09-09 加 cachedTokens) | keep-as-is |
| `state/conversation_export.dart` | 会话导出 | 导出函数 | 无 | core/models | 稳定(`conversation_export_test.dart`) | keep-as-is |
| `state/conversation_search.dart` | 会话内检索纯函数 | 检索函数 | 无 | core/models | 稳定(history_search_test 覆盖) | keep-as-is |

## 5. 特性层(features/)

| 路径 | 职责 | 关键类 | Provider/入口 | 依赖 | 稳定性 | v3 处置 |
| --- | --- | --- | --- | --- | --- | --- |
| `features/shell/home_shell.dart` | 五 Tab 壳 + 全局 init 副作用(226 行) | `HomeShell`、`tabIndexProvider` | 应用 home;消费 scheduler/widget/bg/memory 四个 init 钩子 | core/platform 2 文件 + state 4 文件 + design/tokens + 5 个页面 | 稳定偏变化(PHASE 47 加维护钩子) | wrap-with-facade:v3 新 Home 布局落地时收口 init 副作用 |
| `features/chat/chat_page.dart` | 对话页(2369 行:输入区、转录流、审批弹窗挂载、语音、附件、TTS、上下文量表) | `ChatPage`、`_ChatPageState` | watch `chatSessionProvider`/`settingsStoreProvider`/`approvalQueueProvider`/`workspaceAuthorizedProvider` | state 4 文件、core 3 文件(类型)、platform 3 文件、design 7 文件、approval_sheet | **易碎**(PHASE 48-54 全触及;无页面级测试) | wrap-with-facade:v3 Home/Composer 重做时保留 entry→session API 层 |
| `features/chat/model_picker_sheet.dart` | 模型选择 + 采样参数 | 选择 sheet | read settingsStore | core/gateway 2 文件、state/settings_store | 变化中(PHASE 51) | keep-as-is |
| `features/chat/in_chat_search.dart` | 会话内搜索(PHASE 54) | 搜索 bar | state/chat_session | design、state | 变化中(`in_chat_search_test.dart`) | keep-as-is |
| `features/chat/conversation_actions.dart` | 会话动作菜单 | 动作 sheet | chatSessionProvider | state 2 文件、design | 稳定 | keep-as-is |
| `features/approval/approval_sheet.dart` | 审批弹窗(逐 hunk、always-allow、不可信标记) | 审批 sheet | 注册到 `_ApprovalRouter` | core/models、core/approval_broker(类型)、state/chat_session、design | 变化中(PHASE 48/50) | keep-as-is(v3 演进为审批中心) |
| `features/tasks/tasks_page.dart` | 任务页(统一 runtime 队列 + 定时任务) | `TasksPage` | taskHistoryProvider、scheduler providers | core/task_queue、state/chat_session、scheduled_tasks、design | 变化中(PHASE 45) | keep-as-is(v3 Mission 承接现有 TaskState) |
| `features/history/history_page.dart` | 历史(置顶/检索/重命名/删除/恢复) | `HistoryPage` | settingsStore、chatSession | core/task_recovery(恢复候选)、state、design | 稳定(`history_pin_test.dart`、`history_search_test.dart`) | keep-as-is |
| `features/capabilities/capabilities_page.dart` | 能力页(MCP/DSH/环境检测/信任)(1459 行) | `CapabilitiesPage` | dsh providers、pluginRepoProvider、settingsStore | core 6 文件直连(dsh/mcp/tools/diagnostics)、state 4 文件、platform/process_runner、design | 变化中(PHASE 48) | keep-as-is |
| `features/memory/memory_page.dart` | 记忆页(账本 vitality/整理报告) | `MemoryPage` | hermesLedgerProvider、memoryStoreProvider | core/hermes 3 文件、core/memory、state 4 文件、design | 变化中(PHASE 47/52;`memory_tier_ui_test.dart`) | keep-as-is |
| `features/memory/memory_settings_page.dart` | 记忆设置页 | 设置 sheet | settingsStore | core/hermes/memory_settings、state、design | 稳定 | keep-as-is |
| `features/profile/profile_page.dart` | 我的(模型配置/AgentProfile/外观/LAN/TTS/用量/更新/恢复任务) | `ProfilePage` | themeModeProvider(app.dart)、tabIndexProvider(shell)、settingsStore、lan/update/usage | core 5 文件(agent_profile/crash/gateway×2/error_messages)、state 6 文件、platform、design | 变化中(PHASE 46A) | keep-as-is |
| `features/profile/profile_editor_sheet.dart` | AgentProfile 编辑器 | 编辑 sheet | settingsStore | core/agent_profile、state、design | 稳定 | keep-as-is |

## 6. 平台层(platform/)与设计层(design/)

| 路径 | 职责 | 关键类 | 依赖 | 稳定性 | v3 处置 |
| --- | --- | --- | --- | --- | --- |
| `platform/platform_workspace.dart` | SAF 工作区 + 回退沙箱 + 工厂 | `PlatformWorkspace`、`ResilientWorkspace`、`createWorkspace()` | core/tools/workspace(接口)、flutter/services | 稳定(`workspace_fallback_test.dart`) | keep-as-is |
| `platform/process_runner.dart` / `process_runner_io.dart` / `process_runner_stub.dart` | 进程执行接口 + IO/web 条件实现 | `createProcessRunner()` | core/agent_core、core/shell | 稳定(shell_test) | keep-as-is |
| `platform/secure_box.dart` | API key 安全盒(AndroidKeyStore/web 回退) | `createSecureBox()`、`SecureBox` | flutter/services、shared_preferences | 稳定 | keep-as-is |
| `platform/speech.dart` | 语音输入封装 | stt 封装 | speech_to_text | 稳定 | keep-as-is |
| `platform/conversation_images.dart` | 附件图磁盘缓存 | `ConversationImageStore` | path_provider | 稳定(`conversation_images_test.dart`) | keep-as-is |
| `platform/shared_intent.dart` | 分享接收意图 | intent 封装 | receive_sharing_intent | 稳定 | keep-as-is |
| `platform/task_service.dart` | 任务通知通道 | MethodChannel 封装 | flutter/services | 稳定 | keep-as-is |
| `design/tokens.dart` | 设计令牌(AppTokens/SemanticColors) | 常量 | 无 | 稳定 | keep-as-is |
| `design/theme.dart` | 明暗主题构建 | `buildShellyTheme` | tokens | 变化中(PHASE 49A 暗色打磨) | keep-as-is |
| `design/components/*.dart`(10 个) | 按钮代码块空态头像 markdown 动效风险徽骨架工具卡 | 各组件类 | tokens;**tool_card 额外依赖 state/chat_session.dart(ToolEntry)** | 稳定 | keep-as-is;tool_card 的 ToolEntry 依赖随 chat_session 拆分下沉(see DEPENDENCY_MAP §3.1) |

## 7. 处置汇总

- **keep-as-is(约 80%)**:内核根文件、runtime、tools/shell/workspace、gateway 附属文件、mcp/dsh/lan/tts/crash/git/diagnostics、platform、design、state 的独立 store 文件。
- **wrap-with-facade(6 处)**:`state/chat_session.dart`(装配拆分)、`state/settings_store.dart`(持久化收口)、`core/runtime/agent_runtime.dart`(Brain 组装缝)、`core/gateway/openai_gateway.dart`(预算钩子)、`core/tools/memory_search_tool.dart`(切断 core→state)、`features/shell/home_shell.dart` + `features/chat/chat_page.dart`(init 副作用与会话 API 收口)。
- **move-later(0 处强制)**:v3.0 期间不做目录搬迁;3.1 再议 `core/` → `lib/capability/` 等物理映射(届时按 DEPENDENCY_MAP §2 的实际依赖图执行)。
