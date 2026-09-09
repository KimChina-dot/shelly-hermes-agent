# 测试覆盖地图(TEST_COVERAGE_MAP)

> PHASE 0 审计文档 3-1。基线:**68 个测试文件、648 个用例,`flutter test` 全绿(实测 1:35,2026-09-09);`dart analyze` 退出码 0(No issues found!)**。
> 统计口径:`grep -cE "^\s*(test|testWidgets)\("` 逐文件计数;另有 `flutter test` 实测总数 648(含 group 展开后的重复注册,与静态计数 ≈647 一致)。
> 所有路径均相对 `flutter/`。

## 1. 总览

| 区域 | 文件数 | 用例数(静态) | 覆盖的 lib/ 模块 |
| --- | --- | --- | --- |
| test/core(根) | 24 | ~209 | core 根文件(agent kernel)+ shell/git/workspace/tts/platform |
| test/core/tools | 4 | 56 | core/tools |
| test/core/memory | 5 | 47 | core/memory |
| test/core/mcp | 4 | 71 | core/mcp |
| test/core/lan | 2 | 16 | core/lan |
| test/core/gateway | 4 | 47 | core/gateway |
| test/core/crash | 2 | 13 | core/crash |
| test/state | 12 | 93 | state/* |
| test/features | 1 | 10 | features/chat(in_chat_search) |
| test/capabilities | 1 | 5 | features/capabilities |
| test/memory | 1 | 6 | features/memory + core/hermes |
| test/platform | 2 | 10 | platform/* |
| test/eval | 1(+scenarios) | 4(驱动 10 个场景) | core/agent_core + tools + shell + approval(端到端) |
| test/ 根 | 5 | 45 | app 装配、history、widget 层 |

## 2. 逐目录清单(文件 × 用例数 × 覆盖对象)

### 2.1 test/core(根)— Agent 内核与基础能力

| 文件 | 用例 | 覆盖的 lib/ 模块 |
| --- | --- | --- |
| core/agent_core_test.dart | 13 | core/agent_core.dart(主循环、检查点、限额) |
| core/agent_profile_test.dart | 5 | core/agent_profile.dart |
| core/approval_broker_test.dart | 17 | core/approval_broker.dart(审批队列粘性/超时/决策) |
| core/closed_loop_demo_test.dart | 1 | core/agent_core.dart 演示闭环 |
| core/context_compactor_test.dart | 18 | core/context/context_compactor.dart |
| core/diff_hunk_approval_test.dart | 10 | core/diff_hunk_approval.dart + core/diff_approval.dart |
| core/dsh_test.dart | 16 | core/dsh/*(plugin/installer/tool_registry/registry) |
| core/environment_check_test.dart | 7 | core/diagnostics/environment_checker.dart |
| core/error_messages_test.dart | 3 | core/error_messages.dart |
| core/gateway_test.dart | 14 | core/gateway/openai_gateway.dart + sse.dart + openai_messages.dart |
| core/git_test.dart | 9 | core/git/git_manager.dart + git_sandbox.dart |
| core/hermes_test.dart | 18 | core/hermes/*(hermes_memory/forgetting/knowledge/reflection/memory_settings) |
| core/integration_test.dart | 1 | core 装配集成(ToolAudit 等) |
| core/models_test.dart | 7 | core/models.dart(AgentCheckpoint/AgentMessage/事件族) |
| core/model_discovery_test.dart | 8 | core/gateway/model_discovery.dart |
| core/memory_settings_test.dart | 3 | core/hermes/memory_settings.dart |
| core/runtime_test.dart | 7 | core/runtime/*(agent_runtime/hardened_tool_executor/tool_registry) |
| core/shell_test.dart | 14 | core/shell/shell_executor.dart(策略/风险分级) |
| core/task_queue_test.dart | 5 | core/task_queue.dart(并发协调) |
| core/task_recovery_test.dart | 3 | core/task_recovery.dart(TaskRecoveryRecord) |
| core/task_states_test.dart | 6 | core/task_queue.dart(TaskState/TaskStatus) |
| core/tools_test.dart | 13 | core/tools/registry.dart + audit.dart |
| core/workspace_project_test.dart | 10 | core/workspace/project.dart + workspace_manager.dart |
| core/platform/background_tasks_test.dart | 7 | core/platform/background_tasks.dart |
| core/platform/home_widget_bridge_test.dart | 5 | core/platform/home_widget_bridge.dart |
| core/tts/tts_service_test.dart | 16 | core/tts/tts_service.dart |

### 2.2 test/core/tools

| 文件 | 用例 | 覆盖 |
| --- | --- | --- |
| tools/memory_search_tool_test.dart | 17 | core/tools/memory_search_tool.dart |
| tools/notes_tool_test.dart | 21 | core/tools/notes_tool.dart + **chat_session 的 recitationBodyDecorator(PHASE 53 缓存纪律测试,见 §4)** |
| tools/terminal_tools_test.dart | 12 | core/tools/terminal_tools.dart |
| tools/untrusted_tagging_test.dart | 6 | core/tools(untrusted 输出标记) |

### 2.3 test/core/memory

| 文件 | 用例 | 覆盖 |
| --- | --- | --- |
| memory/chat_memory_test.dart | 1 | core/memory(memory_store 对话桥接) |
| memory/consolidation_test.dart | 11 | core/memory/consolidation.dart |
| memory/memory_backup_test.dart | 6 | core/memory/memory_store.dart 导出/导入(shelly-memory-backup-*.json,见 features/memory/memory_page.dart:54-57) |
| memory/memory_extractor_test.dart | 11 | core/memory/memory_extractor.dart |
| memory/memory_store_test.dart | 18 | core/memory/memory_store.dart(MemoryFact/tier/容量) |

### 2.4 test/core/mcp

| 文件 | 用例 | 覆盖 |
| --- | --- | --- |
| mcp/bridge_test.dart | 30 | core/mcp/bridge_server.dart + bridge_client.dart |
| mcp/bridge_dashboard_test.dart | 9 | core/mcp/bridge_dashboard.dart(终端仪表盘;**含重绘节流时序测试,见 §5**) |
| mcp/mcp_guard_test.dart | 24 | core/mcp/mcp_guard.dart + mcp_tool_registry.dart |
| mcp_test.dart | 8 | core/mcp/mcp_client.dart |

### 2.5 test/core/lan — **LAN 伴生服务器有直接测试**

| 文件 | 用例 | 覆盖 |
| --- | --- | --- |
| lan/lan_companion_server_test.dart | 12 | core/lan/lan_companion_server.dart(HTTP 端点、token 掩码) |
| lan/lan_companion_store_test.dart | 4 | state/lan_companion.dart(开关/token 持久化) |

### 2.6 test/core/gateway

| 文件 | 用例 | 覆盖 |
| --- | --- | --- |
| gateway/cache_metrics_test.dart | 11 | core/gateway(缓存指标,usage.cached_tokens) |
| gateway/model_params_test.dart | 13 | state/settings_store.dart ModelConfig(temperature/topP/maxTokens) |
| gateway/web_search_test.dart | 9 | core/gateway/web_search.dart(**含 gateway bodyDecorator 组合测试,web_search_test.dart:110-118**) |

### 2.7 test/core/crash

| 文件 | 用例 | 覆盖 |
| --- | --- | --- |
| crash/crash_log_store_test.dart | 6 | core/crash/crash_log_store.dart(shelly.crash.logs) |
| crash/crash_logging_test.dart | 7 | core/crash(FlutterError/PlatformDispatcher 挂接) |

### 2.8 test/state

| 文件 | 用例 | 覆盖 |
| --- | --- | --- |
| state/aux_model_test.dart | 10 | state/settings_store.dart 辅助模型配置 |
| state/chat_session_test.dart | 2 | state/chat_session.dart(装配) |
| state/context_meter_test.dart | 5 | state 上下文计量(UI 可见 token 占用) |
| state/conversation_export_test.dart | 4 | state/conversation_export.dart |
| state/memory_maintenance_test.dart | 6 | state/memory_maintenance.dart(三键 lastRun/recallAgeDays/archivalCap) |
| state/plugin_repo_test.dart | 9 | state/plugin_repo.dart(shelly.plugin.installed) |
| state/regenerate_test.dart | 5 | state/chat_session.dart 重新生成 |
| state/scheduled_tasks_test.dart | 23 | state/scheduled_tasks.dart(shelly.sched.tasks) |
| state/session_management_test.dart | 7 | state/chat_session.dart 会话切换/快照 |
| state/steering_test.dart | 8 | state/chat_session.dart PHASE 51/54 排队与打断(**时序敏感,见 §5**) |
| state/update_check_test.dart | 13 | state/update_check.dart(shelly.update.lastcheck) |
| state/usage_stats_test.dart | 12 | state/usage_stats.dart(shelly.usage.stats、缓存命中) |

### 2.9 其余目录

| 文件 | 用例 | 覆盖 |
| --- | --- | --- |
| features/in_chat_search_test.dart | 10 | features/chat/in_chat_search.dart + state/conversation_search.dart(PHASE 54) |
| capabilities/guard_ui_test.dart | 5 | features/capabilities 守卫 UI |
| memory/memory_tier_ui_test.dart | 6 | features/memory/memory_page.dart + core/memory tier |
| platform/conversation_images_test.dart | 4 | platform/conversation_images.dart |
| platform/workspace_fallback_test.dart | 6 | platform/platform_workspace.dart 回退链 |
| history_pin_test.dart(根) | 2 | state/settings_store.dart 会话置顶 |
| history_search_test.dart(根) | 11 | state/conversation_search.dart |
| widget_test.dart(根) | 24 | app.dart + features/shell/home_shell.dart 五 Tab 装配(导航、分享 intent、模型选择、语音、附件、profile、memory 页) |

### 2.10 test/eval — 轨迹级评测基线(PHASE 46)

- `test/eval/README.md` + `test/eval/trajectory_test.dart`(4 个 test)+ `test/eval/scenarios/eval_scenarios.dart`(场景库,`evalScenarios()` 于 eval_scenarios.dart:487)。
- **固定 10 场景**:01-read-and-summarize / 02-write-new-file / 03-apply-patch-existing / 04-search-then-read / 05-create-then-edit / 06-tool-error-recovery / 07-block-destructive-command / 08-memory-injected-answer / 09-no-tool-direct-answer / 10-list-files-then-exists(eval_scenarios.dart:490-807)。
- trajectory_test.dart 断言:场景集恰好 10 个(:28)、全部通过确定性 rubric(:37)、**负对照(自相矛盾场景必须失败)**(:77)、无记忆时不注入 memory 块(:107)。
- 设计:真 AgentCore + 真 WorkspaceToolRegistry/ShellToolRegistry + 真 ToolPolicy,仅网关脚本化、shell 拒绝执行(eval_scenarios.dart:1-25);评分只看产物与轨迹,不用 LLM 评审。
- **迁移含义**:这是 PHASE 46→53 回归的最强闸门;v3 改动 AgentCore/工具注册/审批策略时,`flutter test test/eval` 必须保持 10/10。

## 3. 覆盖空洞(无直接测试)

| 模块 | 证据 | 风险 |
| --- | --- | --- |
| **approval_sheet UI**(features/approval/approval_sheet.dart) | 全 test/ 无任何文件引用 ApprovalSheet(grep 0 命中);approval_broker_test.dart 只测 broker 逻辑 | 审批表单的按键/决策映射无回归保护 |
| **profile_page / profile_editor_sheet / tasks_page / home_shell / chat_page 单页 UI** | 只有 widget_test.dart 的 24 个装配级 testWidgets 间接触达;无逐页测试 | 页面级回归靠装配测试兜底,粒度粗 |
| **platform/task_service.dart、shared_intent.dart、speech.dart** | test/ 无直接引用(widget_test 以 intent/speech 场景间接覆盖两条) | 平台通道薄层,出问题需真机 |
| **core/tools/audit.dart 单独行为** | 仅 core/tools_test.dart、core/integration_test.dart 触及 | 可接受(已有间接覆盖) |
| **state/dsh_provider.dart、state/hermes_provider.dart** | 无直接测试;hermesLedgerProvider 仅经 memory_tier_ui_test 间接触达 | Provider 图改动无独立闸门 |
| **state/conversation_export 的 UI 入口** | conversation_export_test.dart 4 例只测导出逻辑;分享按钮经 widget_test.dart:445 | 可接受 |
| **design/ 主题与动效** | 无测试(纯视觉) | 常规 |
| **integration_test/app_e2e_test.dart** | 存在但不在 `flutter test` 默认集(需真机/模拟器) | CI 只覆盖单元/widget 层 |

注:任务书里点名的疑点逐条核实——**lan companion server 有 12 例直接测试**;**bridge dashboard 有 9 例**;**context meter 有 5 例(state/context_meter_test.dart)**;**in-chat search 有 10 例**;**approval broker 粘性队列有 17 例**。真正的空洞是**审批表单 UI、平台通道薄层、两个 provider 文件**。

## 4. PHASE 46→53 缓存纪律测试(迁移必须保持绿色)

位置:`test/core/tools/notes_tool_test.dart:243-320`,group `recitationBodyDecorator cache discipline (PHASE 53)`:

1. **system message 保持字节级不变**(notes_tool_test.dart:250):计划/笔记变化前后,`recitationBodyDecorator` 产出的 messages[0](system)内容逐字节相同 —— 保证 provider KV 缓存前缀不失配。
2. **recitation 以最后一条 user 消息追加,且替换旧副本**(notes_tool_test.dart:268):断言 last.role=='user'、last.content 含「当前计划」、全表只有 1 条含该标记。
3. **空计划不改动 body**(notes_tool_test.dart:296):消息数不变。

对应实现:`lib/state/chat_session.dart:1068-1093`(strip-then-append,`_recitationMarker` 于 :1095),网关侧 `lib/core/gateway/openai_gateway.dart:301`(`bodyDecorator?.call(body)`)。配套:`test/core/gateway/web_search_test.dart:110-118` 验证装饰器嵌套(webSearch 内层 + recitation 外层,chat_session.dart:1293-1296)。

## 5. 已知时序敏感点(flake 风险)

1. **steering FIFO 在负载下**:test/state/steering_test.dart:142 `queued messages drain FIFO, one per completion` 依赖"完成观察者逐条出队"的真实异步链(scripted gateway 逐轮回放,steering_test.dart:1-40 说明 recording 先于 delay 以缩小竞态窗口)。满载/慢机下 `pumpEventQueue` 式等待可能超时 —— 属"完成后再断言"的结构,单跑稳定,全量并行时是最脆弱的一组。
2. **bridge dashboard 重绘节流**:test/core/mcp/bridge_dashboard_test.dart:293-324 用真实 `Future.delayed` 断言 140ms 突发不重绘、每 ~500ms 至多重绘一次(≈2 次/秒上限)。这是墙钟时序断言,机器卡顿时 2/3 个边界计数会漂移 —— 全套件中唯一硬编码 sleep 的测试。
3. 其余大量测试用 fakeAsync/注入时钟,无此问题;`flutter test` 单次全量实测全绿,但上述两处是 CI 波动的首选嫌疑。

## 6. 维护建议(只记录,不改码)

- approval_sheet、task_service、dsh_provider/hermes_provider 补直接测试是 PHASE 0 后最高性价比的三项。
- bridge_dashboard_test 的墙钟断言可注入 ticker 抽象(与 dashboard 重构一并做),steering_test 可引入可注入调度器消除真实延迟。
