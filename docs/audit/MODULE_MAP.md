# Shelly Hermes 模块地图(PHASE 0 审计 · 工作区 A;PHASE 19 冻结标注)

> 基线 commit `5c46be2`(PHASE 54)逐文件/逐目录盘点 `flutter/lib/`;PHASE 19(V3 计划 P14)在每行追加 **3.1 处置** 列并冻结。
> v3 处置口径(对齐 v3.0 主计划 facade-first 约定):**keep-as-is** = 原样保留;**wrap-with-facade** = 保留原地,新增 facade 导出收口访问;**move-later** = 3.1 再物理移动。
> **3.1 处置口径(PHASE 19 冻结,唯一权威)**:**keep** = 原路径保留,3.1 不搬;**wrap** = 原路径保留,消费面已经 `lib/shelly_facade.dart`(PHASE 16)或 capability 端口(PHASE 12)收口——facade export 行即未来搬迁的唯一改写锚点;**move** = 3.1 物理搬迁,目标路径见列,执行命令与风险见 `docs/audit/V31_MIGRATION_CHECKLIST.md`。
> 稳定性证据:测试文件 + `git log` 近期改动日期(2026-09 当前为 PHASE 44-54 迭代期)。
> 冻结时点:facade 聚合 37 库;features 64/65 处 core/state 直连已收敛(facade 消费 14 文件);唯二例外:`features/approval/approval_sheet.dart`(PHASE 12 端口策略保留 state 直连)与 `design/components/tool_card.dart`(随 M1a 拆分解除)。

## 1. 入口层

| 路径 | 职责 | 关键类/符号 | Provider/入口 | 依赖 | 稳定性 | v3 处置 | 3.1 处置 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `lib/main.dart` | 进程入口:语义树暴露、crash 日志安装、迁移启动串、ProviderScope 根 | `main()`、`_installCrashLogging()` | 应用唯一入口 | `app.dart`、`core/crash/crash_log_store.dart`、`core/migration/migration_bootstrap.dart`(PHASE 18) | 稳定(PHASE 18 接迁移串) | keep-as-is | keep |
| `lib/app.dart` | MaterialApp + 明暗主题 + web `?theme=` 支架 | `ShellyApp` | `themeModeProvider`(StateProvider) | `design/theme.dart`、`features/shell/home_shell.dart` | 稳定 | keep-as-is | keep(themeModeProvider 收口入 state 属 §3.4 P2 项,非 3.1 目录搬迁) |

## 2. 核心层根文件(Agent 内核)

| 路径 | 职责 | 关键类/符号 | Provider/入口 | 依赖 | 稳定性 | v3 处置 | 3.1 处置 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `core/models.dart` | 引擎数据模型(1:1 移植 Kotlin AgentModels.kt) | `AgentMessage`、`ToolCall`、`ModelReply`、`AgentLimits(16/64k/32)`、`PendingToolCall`、`AgentCheckpoint`、`sealed AgentEvent` 家族、`ApprovalDecision` | 被所有层引用 | 仅 `dart:convert` | 稳定(`models_test.dart`;09-07) | keep-as-is | wrap(facade 导出;内核词汇表,永不搬) |
| `core/agent_core.dart` | Agent 主循环:预算检查/压缩/逐 hunk 审批/断点恢复 | `AgentCore.run()`、`ModelGateway`、`StreamingModelGateway`、`ToolExecutor`、`ApprovalGateway`、`CheckpointStore`、`AgentObserver`、`ToolApprovalPolicy`、`AutoApproveReadOnlyPolicy`、`CancelFlag` | 无(被 runtime 调用) | models、approval_broker、gateway(仅 CachedTokensReply 类型)、context、diff_hunk_approval | 稳定(`agent_core_test.dart` 等 6 个测试文件;09-07) | keep-as-is | keep(引擎内核,3.0 分层中 core 保留) |
| `core/approval_broker.dart` | 人工审批挂起 + 会话/持久 always-allow | `ApprovalBroker`、`PendingApproval`、`ApprovalGateway` | 无独立 provider;实例归 ChatSessionController | models | 稳定(`approval_broker_test.dart`;09-09 小改) | keep-as-is | wrap(facade 导出;PHASE 12 已 implements capability/approval 端口) |
| `core/task_queue.dart` | 多任务协调:并发槽、队列、暂停/恢复 | `TaskCoordinator`、`TaskState`(11 态)、`TaskStatus`、`AgentTaskRunner`、`AgentEventReporter` | 经 taskHistoryProvider 输出状态 | agent_core、models | 稳定(`task_queue_test.dart`、`task_states_test.dart`;09-03) | keep-as-is | wrap(facade 导出;Mission=Task 映射基础,不搬) |
| `core/task_recovery.dart` | 进程被杀后的可恢复任务扫描 | `TaskRecoveryRecord`、`RecoveryCandidate`、`TaskRecoveryStore`、`TaskRecovery.scan()` | SettingsStore 实现其 Store 接口 | models、dart:convert | 稳定(`task_recovery_test.dart`) | keep-as-is | wrap(facade 导出) |
| `core/agent_profile.dart` | 人格/限制预设 | `AgentProfile`、`agentProfilePresets` | settings_store 持久化;profile_page 编辑 | gateway/providers(仅 preset id 提示) | 稳定(`agent_profile_test.dart`;09-07) | keep-as-is | wrap(facade 导出) |
| `core/diff_approval.dart` | 逐 hunk 审批 UI 模型 | `DiffHunk` | approval_sheet 渲染 | 无 | 稳定 | keep-as-is | keep |
| `core/diff_hunk_approval.dart` | apply_patch ↔ 逐 hunk 拆分/重组 | `DiffHunkApproval.expand/collapse` | agent_core 循环内调用 | models、dart:convert | 稳定(`diff_hunk_approval_test.dart`) | keep-as-is | keep |
| `core/error_messages.dart` | 异常 → 中文一句话 | `humanizeAgentError()` | chat/model_picker/profile 直接调用 | gateway(GatewayException) | 稳定(`error_messages_test.dart`) | keep-as-is | wrap(facade 导出) |

## 3. 核心层能力目录

| 路径 | 职责 | 关键类/符号 | Provider/入口 | 依赖 | 稳定性 | v3 处置 | 3.1 处置 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `core/runtime/agent_runtime.dart` | 引擎组装:Hermes 回忆/记忆、策略与限制装配 | `AgentRuntime` | 由 ChatSessionController 持有 | agent_core、approval_broker、models、tools/registry、agent_context | 稳定(`runtime_test.dart`) | wrap-with-facade(v3 Brain 需要走同一组装缝) | **move → `lib/agent/runtime/agent_runtime.dart`**(清单 M5;组装职责归 agent 层,Brain 同层) |
| `core/runtime/agent_context.dart` | 运行时参数包 + 记忆接口 | `AgentContext`、`AgentMemoryAccess` | — | agent_core、models、tools/registry、workspace、gateway、context | 稳定 | keep-as-is | keep |
| `core/runtime/tool_registry.dart` | 工具注册表缝 + 组合分发 | `AgentToolRegistry`、`CompositeToolRegistry`(先声明者赢) | — | agent_core、models、tools/registry | 稳定(runtime_test) | keep-as-is | keep(派发顺序是安全属性,tools_test/eval 锁定) |
| `core/runtime/hardened_tool_executor.dart` | 工具执行护栏:120s 超时、20k 截断、模型摘要 | `HardenedToolExecutor` | — | models、tools/registry | 稳定 | keep-as-is | keep |
| `core/tools/workspace.dart` | 工作区存储抽象 + 内存实现 + 工具集 | `Workspace`、`MemoryWorkspace`、`WorkspaceToolRegistry`、`decodeArguments` | `workspaceProvider` 经 platform 工厂注入 | 无(纯 Dart) | 稳定(`tools_test.dart`) | keep-as-is | keep |
| `core/tools/registry.dart` | 工具规格 + 信任策略 | `ToolSpec`、`ToolError`、`ToolPolicy(standard)`、`CompositeToolRegistry` 前置 | — | agent_core、models、runtime/tool_registry、workspace | 稳定 | keep-as-is | wrap(facade 导出) |
| `core/tools/notes_tool.dart` | plan/notes 朗诵状态工具(PHASE 46) | `NotesToolRegistry` | 每次 run 新建 | runtime/tool_registry、tools/registry | 稳定(`notes_tool_test.dart`) | keep-as-is | keep |
| `core/tools/terminal_tools.dart` | fd/rg 结构化搜索 + 回退 | `TerminalSearchTools` | CompositeToolRegistry 成员 | shell/ShellExecutor 经构造注入 runner | 稳定(`terminal_tools_test.dart`) | keep-as-is | keep |
| `core/tools/memory_search_tool.dart` | `search_memory` 自诊断工具(PHASE 43/52) | `MemorySearchToolRegistry` | CompositeToolRegistry 成员 | crash、memory、models、runtime、tools;**反向:state/settings_store.dart(ConversationSummary)** | 稳定(`memory_search_tool_test.dart`) | wrap-with-facade(先切断 core→state 反向依赖) | **move → `lib/capability/tools/memory_search_tool.dart`**(清单 M6;附 ConversationSummary 下沉 `lib/domain/chat/conversation_summary.dart`,切断全库唯一 core→state 边) |
| `core/tools/audit.dart` | 工具活动 JSONL 审计 | `AuditSink`、`InMemoryAuditSink`、`JsonlAuditLog`(AgentObserver) | 可选挂 observer | agent_core、models | 稳定 | keep-as-is | keep |
| `core/shell/shell_executor.dart` | Shell 策略/风险分类/执行/工具/审批策略 | `ShellPolicy`、`ShellRiskClassifier`、`ShellExecutor`、`ShellToolRegistry`、`ShellApprovalPolicy`、`ProcessRunner` 接口 | CompositeToolRegistry 成员 | agent_core、models、runtime、tools;runner 来自 platform | 稳定(`shell_test.dart`;09-02) | keep-as-is | keep |
| `core/gateway/openai_gateway.dart` | OpenAI 兼容网关(流式、KV-cache、body 装饰器) | `OpenAiCompatibleGateway`、`ChatTransport`、`HttpChatTransport`、`GatewayException`、`CachedTokensReply` | `chatGatewayOverrideProvider` 测试缝 | agent_core(models)、openai_messages、sse、http | 变化中(PHASE 46A/51 触及;09-09) | wrap-with-facade(v3 Brain 调用必须计入 64K 预算) | keep(预算钩子已由 `lib/agent/brain/brain_gateway.dart` PHASE 8 落地;网关本体原路径保留) |
| `core/gateway/openai_messages.dart` | 请求/响应编码 | 消息编码函数 | — | models | 稳定 | keep-as-is | keep |
| `core/gateway/sse.dart` | SSE 解析 | `SseParser` | — | 无 | 稳定(gateway_test) | keep-as-is | keep |
| `core/gateway/providers.dart` | 内置 provider 预设 | `LlmProviderPreset`、`llmProviderPresets` | profile/model_picker 页 UI 数据 | 无 | 稳定 | keep-as-is | wrap(facade 导出) |
| `core/gateway/model_discovery.dart` | `/v1/models` 拉取 | `ModelDiscovery`、`RemoteModel`、`ModelsTransport` | settings_store 拉模型列表 | http | 稳定(`model_discovery_test.dart`) | keep-as-is | wrap(facade 导出) |
| `core/gateway/context_window.dart` | 模型上下文窗估算 | 估算函数 | settings_store/compactor 使用 | 无 | 稳定 | keep-as-is | keep |
| `core/gateway/web_search.dart` | web 搜索请求改写装饰器 | `webSearchBodyDecorator` | 网关 bodyDecorator 链 | openai_gateway | 稳定(`web_search_test.dart`) | keep-as-is | keep |
| `core/memory/memory_store.dart` | 分层事实存储(PHASE 52) | `MemoryFact`、`MemoryStore`、`ImportReport` | `memoryStoreProvider` | shared_preferences | 变化中(`chat_memory/memory_store/memory_backup_test.dart`) | keep-as-is | wrap(facade 导出) |
| `core/memory/memory_extractor.dart` | 会话结束自动抽取事实 | `MemoryExtractor` | observer 侧使用 | gateway | 变化中(`memory_extractor_test.dart`) | keep-as-is | keep |
| `core/memory/consolidation.dart` | 睡眠时合并/老化 | `MemoryConsolidator`、`ConsolidationReport` | MemoryMaintenanceService 调用 | memory_store | 变化中(`consolidation_test.dart`) | keep-as-is | keep |
| `core/hermes/knowledge.dart` | 知识条目模型 | `KnowledgeEntry`、`KnowledgeVitality`、`estimateTokens` | — | 无 | 稳定(`hermes_test.dart`) | keep-as-is | wrap(facade 导出) |
| `core/hermes/knowledge_store.dart` | 知识账本存取 | `HermesKnowledgeStore` | _TaskRunner/hermes_provider 构建 | tools/workspace、knowledge | 稳定 | keep-as-is | keep |
| `core/hermes/knowledge_tool.dart` | append/recall 知识工具 | `KnowledgeToolRegistry` | CompositeToolRegistry 成员 | knowledge_store、runtime、tools | 稳定 | keep-as-is | keep |
| `core/hermes/hermes_memory.dart` | 任务前回忆/任务后记忆 | `HermesMemory implements AgentMemoryAccess` | AgentContext.hermes | knowledge_store、runtime、forgetting | 稳定 | keep-as-is | keep |
| `core/hermes/forgetting.dart` | 遗忘策略 | `ForgettingPolicy`、`ForgettingReport` | settings 注入 | 无 | 稳定 | keep-as-is | wrap(facade 导出) |
| `core/hermes/reflection.dart` | 泛化/合并反思 | `Reflector`、`ReflectionReport` | hermes_provider 手动整理 | knowledge_store | 稳定 | keep-as-is | keep |
| `core/hermes/memory_settings.dart` | 记忆设置模型 | `MemorySettings` | settings_store 持久化 | 无 | 稳定(`memory_settings_test.dart`) | keep-as-is | wrap(facade 导出) |
| `core/context/context_compactor.dart` | 上下文压缩(PHASE 46B 可恢复) | `ContextCompactor`、`CompactionResult` | AgentContext.contextCompactor | gateway(摘要网关)、models | 稳定(`context_compactor_test.dart`;09-08) | keep-as-is | keep |
| `core/mcp/mcp_client.dart` | MCP 客户端(HTTP/SSE) | `McpClient`、`McpServerConfig`、`McpToolInfo` | settings_store 存配置 | http、crypto | 稳定(`mcp_test.dart`) | keep-as-is | wrap(facade 导出;capability/mcp/mcp_capability_bridge 已挂端口) |
| `core/mcp/mcp_tool_registry.dart` | MCP 工具表 | `McpToolRegistry` | _TaskRunner 接入 | mcp_client、mcp_guard、runtime | 变化中(PHASE 48) | keep-as-is | keep |
| `core/mcp/mcp_guard.dart` | 供应链指纹守卫(PHASE 46A) | `McpGuard`、`McpGuardLedger`、`McpGuardReport` | 能力页展示 verdict | crypto、mcp_client | 变化中(`mcp_guard_test.dart`) | keep-as-is | wrap(facade 导出) |
| `core/mcp/bridge_client.dart` | 桌面 sidecar 桥客户端(PHASE 45) | `BridgeToolRegistry` | _TaskRunner 接入 | http、runtime | 稳定(`bridge_test.dart`) | keep-as-is | keep |
| `core/mcp/bridge_server.dart` | stdio↔HTTP 桥服务(桌面侧) | `BridgeServer`、`BridgeConfig` | 桌面 host 启动 | dart:io | 稳定(`bridge_test.dart`;09-07) | keep-as-is | keep |
| `core/mcp/bridge_dashboard.dart` | 桥调用仪表(PHASE 49) | `BridgeDashboard`、`BridgeCallLog` | 桌面 host | 无 | 稳定(`bridge_dashboard_test.dart`) | keep-as-is | keep |
| `core/dsh/manifest.dart` | 插件清单/权限模型 | `DshManifest`、`DshPermissions`、`DshToolDecl` | installer 解析 | 无 | 稳定(`dsh_test.dart`;09-03) | keep-as-is | keep |
| `core/dsh/plugin.dart` | 插件接口与宿主上下文 | `DshPlugin`、`DshHostContext`、`DshTool`、`ShellPlugin` | registry 注册 | tools/workspace | 稳定 | keep-as-is | wrap(facade 导出) |
| `core/dsh/registry.dart` | 插件注册表 | `DshPluginRegistry` | dshRegistryProvider | plugin、manifest | 稳定 | keep-as-is | keep |
| `core/dsh/tool_registry.dart` | 插件工具表 + 信任策略 | `DshToolRegistry`、`DshTrustPolicy`、`DshTrust` | `dshToolsProvider` | runtime、registry | 稳定 | keep-as-is | wrap(facade 导出) |
| `core/dsh/installer.dart` | 插件安装流程 | `DshInstaller` | 能力页调用 | manifest、registry、platform process_runner | 稳定 | keep-as-is | wrap(facade 导出) |
| `core/dsh/hermes_bridge.dart` | 插件 ↔ Hermes 账本桥 | `DshHermesBridge` | 可选 | hermes | 稳定 | keep-as-is | keep |
| `core/workspace/workspace_manager.dart` | 项目检测/快照/根持久化 | `WorkspaceManager`、`WorkspaceSnapshot(Diff)`、`WorkspaceStateStore` | `workspaceManagerProvider` | tools/workspace、project | 稳定(`workspace_project_test.dart`) | keep-as-is | keep |
| `core/workspace/project.dart` | 项目识别 | `ProjectDetector`、`ProjectInfo` | manager 内部 | 无 | 稳定 | keep-as-is | keep |
| `core/git/git_manager.dart` | git 状态/操作 | `GitManager`、`GitStatus` | 能力页/任务流可用 | platform process_runner | 稳定(`git_test.dart`;09-02) | keep-as-is | keep |
| `core/git/git_sandbox.dart` | git 沙箱回滚 | `GitSandbox`、`SandboxSession`、`RollbackReport` | GitManager 协作 | git_manager、workspace | 稳定 | keep-as-is | keep |
| `core/lan/lan_companion_server.dart` | LAN 伴生 HTTP 服务(PHASE 42) | `LanCompanionServer` | `lanCompanionProvider` 启停 | dart:io | 稳定(`lan_companion_server_test.dart`、`lan_companion_store_test.dart`) | keep-as-is | keep |
| `core/tts/tts_service.dart` | 朗读服务 | `TtsService`、`FlutterTtsService` | chat_page 直接使用 | flutter_tts | 稳定(`tts_service_test.dart`) | keep-as-is | wrap(facade 导出) |
| `core/platform/background_tasks.dart` | 后台任务唤醒桥(PHASE 45) | `BackgroundTaskBridge` | home_shell + scheduled_tasks | flutter/services | 稳定(`background_tasks_test.dart`;09-07) | keep-as-is | wrap(facade 导出) |
| `core/platform/home_widget_bridge.dart` | 桌面小组件桥(PHASE 42) | `HomeWidgetBridge` | home_shell | flutter/services | 稳定(`home_widget_bridge_test.dart`) | keep-as-is | wrap(facade 导出) |
| `core/crash/crash_log_store.dart` | 崩溃日志存取 | `CrashEntry`、`CrashLogStore`、`installCrashLogging` | main.dart 安装;memory_search/profile 读取 | shared_preferences | 稳定(`crash_log_store_test.dart`、`crash_logging_test.dart`) | keep-as-is | wrap(facade 导出) |
| `core/diagnostics/environment_checker.dart` | 环境自检(fd/rg/node 等) | `EnvironmentChecker`、`EnvironmentCheck` | 能力页 | shell runner | 稳定(`environment_check_test.dart`) | keep-as-is | wrap(facade 导出) |

## 4. 状态层(state/)

| 路径 | 职责 | 关键类/符号 | Provider | 依赖 | 稳定性 | v3 处置 | 3.1 处置 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `state/chat_session.dart` | 会话控制器 + 引擎装配(1899 行,状态层最大文件) | `ChatSessionController`、`ChatSessionState`、`ChatEntry` 族(User/Assistant/Tool/NoticeEntry)、`_TaskRunner`、`DemoModelGateway`、`_StoreCheckpoints`、`_SessionObserver` | `chatSessionProvider`、`workspaceProvider`、`workspaceAuthorizedProvider`、`workspaceManagerProvider`、`approvalQueueProvider`、`taskHistoryProvider`、`conversationImageStoreProvider`、`chatGatewayOverrideProvider`、`memoryStoreProvider` | core 30+ 文件 + platform 4 个 + domain/agent/capability/skills 新路径 + dsh/settings/usage | **易碎/最热**(每版必改;`chat_session_test.dart`、`regenerate_test.dart`、`session_management_test.dart`、`steering_test.dart`、`context_meter_test.dart`、`aux_model_test.dart` 等 23 个测试文件直连) | wrap-with-facade:v3 拆出"运行时装配工厂"与"会话 UI 状态"两块;facade 暴露 send/approve/steer | **move → 三拆**(清单 M1:`lib/domain/chat/chat_entry.dart` ChatEntry 族 + `lib/agent/session_runtime.dart` _TaskRunner 装配 + `lib/application/chat_session_controller.dart` 控制器余量) |
| `state/settings_store.dart` | 全部 `shelly.*` 键读写中心(586 行) | `SettingsStore implements TaskRecoveryStore`、`ModelConfig`、`ConversationSummary`、`McpBridgeConfig`、`McpStdioServerConfig` | `settingsStoreProvider` | core/agent_profile、gateway/context_window、hermes/memory_settings、models、mcp/mcp_client、task_recovery、platform/secure_box | 稳定偏热(PHASE 51 加采样参数) | wrap-with-facade:v3 持久化迁移的收口点 | wrap(原路径保留;R1 32 键与 MigrationManager 锚定此文件,整体搬迁零收益;仅 ConversationSummary 随 M6 下沉 domain) |
| `state/scheduled_tasks.dart` | 定时任务存储/调度/心跳(523 行) | `ScheduledTask`、`ScheduledTaskStore`、`SchedulerService`、`SchedulerTicker` | `scheduledTaskStoreProvider`、`schedulerServiceProvider`、`scheduledTasksRevisionProvider` | core/platform/background_tasks、gateway、models、settings_store | 稳定(`scheduled_tasks_test.dart`) | keep-as-is | wrap(facade 导出;任务域词汇归 core/task_queue,不搬) |
| `state/dsh_provider.dart` | DSH 三个 provider 组装(21 行) | — | `dshRegistryProvider`、`dshTrustProvider`、`dshToolsProvider` | core/dsh | 稳定 | keep-as-is | **move → `lib/capability/dsh/dsh_provider.dart`**(清单 M2;能力层 provider 装配归位,同时消除 capability→state 反向边 dynamic_skill_host→dsh_provider) |
| `state/hermes_provider.dart` | 记忆页账本快照 + 手动整理 | `HermesLedgerSnapshot`、`runUpkeepWith`、`UpkeepReport` | `hermesLedgerProvider`(autoDispose) | core/hermes 5 文件 + tools/workspace + chat_session + settings_store | 稳定 | keep-as-is | **move → `lib/application/hermes_provider.dart`**(清单 M3;跨 core/hermes 与 state 的快照编排属 application 层,与 mission_coordinator 同层) |
| `state/lan_companion.dart` | LAN 开关/令牌/控制器 | `LanCompanionStore`、`LanCompanionState`、`LanCompanionController` | `lanCompanionProvider` | core/lan、models、settings_store、update_check | 稳定 | keep-as-is | wrap(facade 导出) |
| `state/memory_maintenance.dart` | 日节流维护触发(PHASE 47) | `MemoryMaintenanceService` | 无(服务,由 shell 触发) | core/memory/consolidation、memory_store | 稳定(`memory_maintenance_test.dart`) | keep-as-is | **move → `lib/application/memory_maintenance.dart`**(清单 M4;维护服务编排属 application 层) |
| `state/plugin_repo.dart` | 插件预设仓库 | `PluginPreset`、`PluginRepoStore` | `pluginRepoProvider` | shared_preferences | 稳定(`plugin_repo_test.dart`) | keep-as-is | wrap(facade 导出) |
| `state/update_check.dart` | 版本检查(节流) | `UpdateCheckResult`、`UpdateCheckService` | `updateCheckProvider` | http、package_info_plus | 稳定(`update_check_test.dart`) | keep-as-is | wrap(facade 导出) |
| `state/usage_stats.dart` | 用量统计(含 KV-cache 指标) | `UsageEntry`、`UsageTotals`、`UsageStatsStore` | `usageStatsProvider` | shared_preferences | 稳定(`usage_stats_test.dart`;09-09 加 cachedTokens) | keep-as-is | wrap(facade 导出;64K 预算账本,Brain 计入点) |
| `state/conversation_export.dart` | 会话导出 | 导出函数 | 无 | core/models | 稳定(`conversation_export_test.dart`) | keep-as-is | wrap(facade 导出) |
| `state/conversation_search.dart` | 会话内检索纯函数 | 检索函数 | 无 | core/models | 稳定(history_search_test 覆盖) | keep-as-is | wrap(facade 导出) |

## 5. 特性层(features/)

| 路径 | 职责 | 关键类 | Provider/入口 | 依赖 | 稳定性 | v3 处置 | 3.1 处置 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `features/shell/home_shell.dart` | 五+一 Tab 壳 + 全局 init 副作用(226 行) | `HomeShell`、`tabIndexProvider` | 应用 home;消费 scheduler/widget/bg/memory 四个 init 钩子 | facade + core/platform 2 文件 + state 4 文件 + design/tokens + 6 个页面 | 稳定偏变化(PHASE 13 挂 Mission Timeline Tab) | wrap-with-facade:v3 新 Home 布局落地时收口 init 副作用 | keep(features 物理路径保留;init 副作用收口属 P11 余量,非 3.1 目录搬迁) |
| `features/chat/chat_page.dart` | 对话页(2363 行:输入区、转录流、审批弹窗挂载、语音、附件、TTS、上下文量表) | `ChatPage`、`_ChatPageState` | watch `chatSessionProvider`/`settingsStoreProvider`/`approvalQueueProvider`/`workspaceAuthorizedProvider` | facade、platform 3 文件、design 7 文件、approval_sheet | **易碎**(无页面级测试,由 state 层测试兜底) | wrap-with-facade:v3 Home/Composer 重做时保留 entry→session API 层 | keep(UI 拆分属 3.0 P11 余量;3.1 只搬 core/state,页面经 facade 消费自动受益) |
| `features/chat/model_picker_sheet.dart` | 模型选择 + 采样参数 | 选择 sheet | read settingsStore | facade | 变化中(PHASE 51) | keep-as-is | keep |
| `features/chat/in_chat_search.dart` | 会话内搜索(PHASE 54) | 搜索 bar | facade | design、facade | 变化中(`in_chat_search_test.dart`) | keep-as-is | keep |
| `features/chat/conversation_actions.dart` | 会话动作菜单 | 动作 sheet | facade | facade、design | 稳定 | keep-as-is | keep |
| `features/approval/approval_sheet.dart` | 审批弹窗(逐 hunk、always-allow、不可信标记) | 审批 sheet | 注册到 `_ApprovalRouter` | capability/approval 端口(PHASE 12)+ state/chat_session 直连(approvalQueueProvider)+ design | 变化中(PHASE 48/50) | keep-as-is(v3 演进为审批中心) | keep(M1c 改写其 chat_session 直连;端口策略不变) |
| `features/tasks/tasks_page.dart` | 任务页(统一 runtime 队列 + 定时任务) | `TasksPage` | facade | facade、design | 变化中(PHASE 45) | keep-as-is(v3 Mission 承接现有 TaskState) | keep |
| `features/history/history_page.dart` | 历史(置顶/检索/重命名/删除/恢复) | `HistoryPage` | facade | facade、design、conversation_actions | 稳定(`history_pin_test.dart`、`history_search_test.dart`) | keep-as-is | keep |
| `features/capabilities/capabilities_page.dart` | 能力页(MCP/DSH/环境检测/信任)(1449 行) | `CapabilitiesPage` | facade、process_runner | facade、platform、design | 变化中(PHASE 48) | keep-as-is | keep |
| `features/memory/memory_page.dart` | 记忆页(账本 vitality/整理报告) | `MemoryPage` | facade | facade、design | 变化中(`memory_tier_ui_test.dart`) | keep-as-is | keep |
| `features/memory/memory_settings_page.dart` | 记忆设置页 | 设置 sheet | facade | facade、design | 稳定 | keep-as-is | keep |
| `features/profile/profile_page.dart` | 我的(模型配置/AgentProfile/外观/LAN/TTS/用量/更新/恢复任务)(1349 行) | `ProfilePage` | themeModeProvider(app.dart)、tabIndexProvider(shell)、facade | app.dart、shell、facade、platform、design | 变化中(PHASE 46A) | keep-as-is | keep |
| `features/profile/profile_editor_sheet.dart` | AgentProfile 编辑器 | 编辑 sheet | facade | facade、design | 稳定 | keep-as-is | keep |
| `features/missions/mission_timeline_page.dart` | 使命时间线(PHASE 13,第 6 Tab) | `MissionTimelinePage` | missionCoordinator/facade/domain | application/mission_coordinator、domain/agent/mission、facade、design | 稳定(`mission_timeline_test.dart`) | (PHASE 13 新增) | keep(新路径) |
| `features/missions/mission_detail_page.dart` | 使命详情(PHASE 13,只读) | MissionDetailPage | missionCoordinator/facade/domain | application/mission_coordinator、domain/agent/mission、facade、design | 稳定(`mission_timeline_test.dart`) | (PHASE 13 新增) | keep(新路径) |

## 6. 平台层(platform/)与设计层(design/)

| 路径 | 职责 | 关键类 | 依赖 | 稳定性 | v3 处置 | 3.1 处置 |
| --- | --- | --- | --- | --- | --- | --- |
| `platform/platform_workspace.dart` | SAF 工作区 + 回退沙箱 + 工厂 | `PlatformWorkspace`、`ResilientWorkspace`、`createWorkspace()` | core/tools/workspace(接口)、flutter/services | 稳定(`workspace_fallback_test.dart`) | keep-as-is | keep |
| `platform/process_runner.dart` / `process_runner_io.dart` / `process_runner_stub.dart` | 进程执行接口 + IO/web 条件实现 | `createProcessRunner()` | core/agent_core、core/shell | 稳定(shell_test) | keep-as-is | keep |
| `platform/secure_box.dart` | API key 安全盒(AndroidKeyStore/web 回退) | `createSecureBox()`、`SecureBox` | flutter/services、shared_preferences | 稳定 | keep-as-is | keep |
| `platform/speech.dart` | 语音输入封装 | stt 封装 | speech_to_text | 稳定 | keep-as-is | keep |
| `platform/conversation_images.dart` | 附件图磁盘缓存 | `ConversationImageStore` | path_provider | 稳定(`conversation_images_test.dart`) | keep-as-is | keep |
| `platform/shared_intent.dart` | 分享接收意图 | intent 封装 | receive_sharing_intent | 稳定 | keep-as-is | keep |
| `platform/task_service.dart` | 任务通知通道 | MethodChannel 封装 | flutter/services | 稳定 | keep-as-is | keep |
| `design/tokens.dart` | 设计令牌(AppTokens/SemanticColors) | 常量 | 无 | 稳定 | keep-as-is | keep |
| `design/theme.dart` | 明暗主题构建 | `buildShellyTheme` | tokens | 变化中(PHASE 49A 暗色打磨) | keep-as-is | keep |
| `design/components/*.dart`(10 个) | 按钮代码块空态头像 markdown 动效风险徽骨架工具卡 | 各组件类 | tokens;**tool_card 额外依赖 state/chat_session.dart(ToolEntry)** | 稳定 | keep-as-is;tool_card 的 ToolEntry 依赖随 chat_session 拆分下沉 | keep(M1a 后 tool_card 改依赖 `lib/domain/chat/chat_entry.dart`,反向边 §3.2 消除) |

## 7. v3.0 增量模块(PHASE 1-18 新路径,3.0 决议原路径即终位)

| 路径 | 职责 | 落地 | 3.1 处置 |
| --- | --- | --- | --- |
| `lib/domain/agent/goal.dart` / `mission.dart` / `task.dart` / `step.dart` / `action.dart` | Mission 域只读模型(与 core/task_queue、models 的映射器) | PHASE 1 | keep(新路径终位) |
| `lib/domain/agent/mission_store.dart` | MissionStore 只读查询 | PHASE 1 | keep |
| `lib/agent/brain/intent_router.dart` / `planner.dart` / `brain_gateway.dart` | Brain:意图路由/脚本化规划/共享预算网关 | PHASE 3、8 | keep |
| `lib/application/mission_coordinator.dart` | task 生命周期 ↔ Mission 域桥接 | PHASE 2 | keep |
| `lib/capability/registry/capability.dart` / `capability_registry.dart` / `capability_router.dart` | 统一能力注册/路由 | PHASE 4 | keep |
| `lib/capability/trust/trust_score.dart` / `trust_store.dart` | 能力信任分与账本(`shelly.capability.trust`) | PHASE 4 | keep |
| `lib/capability/approval/approval_port.dart` | ApprovalPort 审批端口 | PHASE 12 | keep |
| `lib/capability/dsh/dynamic_skill_host.dart` | DSH 插件挂为 capability | PHASE 6 | keep(M2 后其 `../../state/dsh_provider.dart` 直连变为同目录) |
| `lib/capability/mcp/mcp_capability_bridge.dart` | MCP servers as capabilities | PHASE 7 | keep |
| `lib/capability/skills/skill_tool_registry.dart` / `task_capability_availability.dart` | list_skills/use_skill 工具面 + 能力可用集 | PHASE 9、17 | keep |
| `lib/skills/skill_definition.dart` / `skill_registry.dart` / `builtin_skills.dart` | 技能定义/注册/内置技能 | PHASE 5 | keep |
| `lib/core/events/agent_events.dart` / `event_bus.dart` | MissionEvent/AgentEventBus | PHASE 1 | keep |
| `lib/core/migration/migration_manager.dart` / `migration_keys.dart` / `migration_prefs.dart` / `migration_bootstrap.dart` | 五段式迁移 + R1 键 spec + 启动接线 | PHASE 10、18 | keep |
| `lib/shelly_facade.dart` | core/state 聚合导出(37 库),3.1 搬迁唯一改写锚点 | PHASE 16 | keep(过渡期后随 3.2 删除,V3_MIGRATION_PLAN §4) |

## 8. 处置汇总(PHASE 19 冻结)

> 旧 v3 处置口径下的汇总保留如下;**3.1 处置** 逐行见上表各节,权威执行清单 = `docs/audit/V31_MIGRATION_CHECKLIST.md`。

- **旧口径 keep-as-is(约 80%)**:内核根文件、runtime、tools/shell/workspace、gateway 附属文件、mcp/dsh/lan/tts/crash/git/diagnostics、platform、design、state 的独立 store 文件。
- **旧口径 wrap-with-facade(6 处)**:`state/chat_session.dart`(装配拆分)、`state/settings_store.dart`(持久化收口)、`core/runtime/agent_runtime.dart`(Brain 组装缝)、`core/gateway/openai_gateway.dart`(预算钩子,已由 brain_gateway 落地)、`core/tools/memory_search_tool.dart`(切断 core→state)、`features/shell/home_shell.dart` + `features/chat/chat_page.dart`(init 副作用与会话 API 收口)。
- **旧口径 move-later(0 处强制)**:v3.0 期间不做目录搬迁;3.1 按 DEPENDENCY_MAP §2 的实际依赖图执行(本 PHASE 19 已落定清单)。

**3.1 处置统计(冻结)**:legacy 表 99 行 = keep 62 + wrap 31 + move 6;§7 新路径 14 行(按文件组计)全 keep。move 6 项 = M1 `state/chat_session.dart`(三拆,高风险)、M2 `state/dsh_provider.dart`、M3 `state/hermes_provider.dart`、M4 `state/memory_maintenance.dart`、M5 `core/runtime/agent_runtime.dart`、M6 `core/tools/memory_search_tool.dart`(含 ConversationSummary 下沉)。wrap 31 项 = shelly_facade 现导出的 37 库减去 4 个 state move 项、再减去归入 §7 的 core/events 2 库。
