# v3 迁移风险登记册(MIGRATION_RISK)

> PHASE 0 审计文档 3-2。诚实评估 Shelly Hermes v2.3(代码基线 5c46be2,PHASE 54)→ v3.0 迁移的真实风险。所有条目均以读到的代码为准;评级 = 可能性 × 影响。
> 佐证基线:`flutter test` 648 全绿、`dart analyze` 0 问题(2026-09-09 实测,见 TEST_COVERAGE_MAP.md)。

---

## R1. SharedPreferences 持久载荷必须原样存活(可能性:高 × 影响:高)

`grep "'shelly\|\"shelly"` 全 lib/ 去重后的**全部键**(32 个)。v3 重写/搬迁任何存储类时,旧版本升级安装后这些键必须仍可读;形状变更必须有兼容读。

### 1.1 state/settings_store.dart(设置与会话主仓)

| 键 | 位置 | 形状 | 若破坏会怎样 |
| --- | --- | --- | --- |
| `shelly.model.config` | settings_store.dart:237 | ModelConfig.toJson()(baseUrl/apiKey 置空/model/temperature/topP/maxTokens 等;apiKey 实际走 secure storage,settings_store.dart:271-274) | 模型全失配,需重配 |
| `shelly.model.aux` | :238 | ModelConfig(辅助"便宜"模型) | 摘要/压缩任务降级或失败 |
| `shelly.model.aux.enabled` | :239 | bool | 辅助通道静默失效 |
| `shelly.conversations` | :241 | `List<ConversationSummary.toJson()>`(id/title/updatedAt/messageCount/pinned/modelId,settings_store.dart:106-135) | **历史列表清零**——用户可感知的最重损失 |
| `shelly.checkpoint.<conversationId>` | :242(前缀键) | `AgentCheckpoint.encode()`(JSON 字符串,见 R3) | 进行中任务无法恢复 |
| `shelly.agent.profiles` | :243 | `List<AgentProfile.toJson()>` | 自定义人格丢失 |
| `shelly.agent.profile.active` | :244 | String(id) | 回退到 profiles.first |
| `shelly.task.active` | :245 | `TaskRecoveryRecord.encode()`(见 R3) | 后台任务恢复失效 |
| `shelly.memory.settings` | :246 | JSON(记忆注入开关/参数) | 记忆行为回默认 |
| `shelly.mcp.servers` | :247 | `List<McpServerConfig.toJson()>` | MCP 连接器配置丢失 |
| `shelly.mcp.stdio` | :248 | stdio 服务器配置 JSON | 同上 |
| `shelly.mcp.toolprints` | :249 | 工具指纹 JSON(变更检测) | 首轮全量重扫 |
| `shelly.tts.enabled` | :250 | bool | 语音开关复位 |
| `shelly.mcp.bridge` | :501 | McpBridgeConfig(baseUrl/token,:173-175) | bridge 断连需重配 |

legacy 迁移点:`restoreApiKey()`(settings_store.dart:277-298)从旧 prefs JSON 里把 apiKey 搬进 secure storage——v3 存储改造不得删掉这条迁移路径。

### 1.2 其他文件

| 键 | 位置 | 形状 | 若破坏 |
| --- | --- | --- | --- |
| `shelly.memory.facts` | core/memory/memory_store.dart:134 | `List<MemoryFact.toJson()>`(id/text/createdAt/tier/sourceConversationId,:23-30,:43-52) | **长期记忆全丢**(最高价值资产) |
| `shelly.crash.logs` | core/crash/crash_log_store.dart:54 | `List<CrashEntry.toJson()>`(:27-34) | 崩溃史清零(低危) |
| `shelly.usage.stats` | state/usage_stats.dart:119 | UsageEntry 列表(按模型/日聚合、cachedTokens) | 用量统计清零 |
| `shelly.sched.tasks` | state/scheduled_tasks.dart:174 | `List<ScheduledTask.toJson()>`(:111-123) | **定时任务全部消失** |
| `shelly.memory.maintenance.lastRun` / `shelly.memory.recallAgeDays` / `shelly.memory.archivalCap` | state/memory_maintenance.dart:37-43(写入侧另有 features/memory/memory_settings_page.dart:28-29) | 标量(int/datetime) | 保养节奏复位,可自愈 |
| `shelly.lan.enabled` / `shelly.lan.token` | state/lan_companion.dart:20-21 | bool / String | LAN 配对失效需重配 |
| `shelly.plugin.installed` | state/plugin_repo.dart:98 | `List<String>` 已装插件 id | DSH 插件目录清零 |
| `shelly.update.lastcheck` | state/update_check.dart:74 | int(millis) | 无害 |
| `shelly.secure.<name>` | platform/secure_box.dart:33 | secure storage 前缀(AndroidKeyStore 经 `dev.shelly/secure_store` channel) | **apiKey 丢失**——model.config 里已置空,破坏它等于断网 |
| `shelly.sched.bgstate` | core/platform/background_tasks.dart:12,81(注释指明由 Dart 写、原生 WorkManager 读) | JSON(到期任务计数) | 后台兜底检查失效 |

**缓解**:v3 存储层必须做"读旧写新"双格式期;上表键名即验收清单;每个键至少一个回读测试(memory_store_test、scheduled_tasks_test 等已覆盖大半)。

---

## R2. PHASE 46→53 复诵机制不得回归(可能性:中 × 影响:高)

机制:每轮请求经 `recitationBodyDecorator`(lib/state/chat_session.dart:1068-1093)**把「当前计划」块作为最后一条 user 消息追加**,并先 strip 旧副本;实现上它包在 `webSearchBodyDecorator` 之外(chat_session.dart:1293-1296),最终在 `openai_gateway.dart:301` 生效。

**为什么高风险**:provider 的 KV prompt 缓存按前缀匹配。recitation 必须只动尾部——system 消息字节级不变是硬约束。位置错了(插到中间)会令每轮缓存全失配,token 成本与延迟暴涨,且不报任何错。

**守门测试**(必须持续绿色,TEST_COVERAGE_MAP.md §4):
- notes_tool_test.dart:250 `system message stays byte-identical while the plan changes`
- notes_tool_test.dart:268 `recitation rides as the LAST message, replacing any stale copy`
- notes_tool_test.dart:296 `empty plan leaves the body untouched`
- web_search_test.dart:110-118 装饰器嵌套组合
- test/eval 10 场景(含 08-memory-injected-answer 验 system 组装)

**缓解**:v3 Brain 层任何"在请求上附加状态"的新机制都复用 RequestBodyDecorator 管道,禁止自行拼 messages;上述 5 组测试列入每阶段闸门。

---

## R3. 检查点格式兼容(在途任务跨版本恢复)(可能性:中 × 影响:中高)

两个编码面:

1. **AgentCheckpoint**(core/models.dart:206-252):`{version:1, messages[], round, consumedTokens, toolCalls, pendingToolCalls[]}`;`fromJson` 对 version≠1 直接抛 `FormatException`(models.dart:231-235)。存于 `shelly.checkpoint.<conversationId>`(settings_store.dart:395-405)。
2. **TaskRecoveryRecord**(core/task_recovery.dart:13-43):`{conversationId, taskId, startedAt(ISO8601)}`,存于 `shelly.task.active`;解析失败静默返回 null(settings_store.dart:560-570)。

风险:v3 若给 checkpoint 加字段/升 version,升级瞬间**正在运行任务的**用户会遭遇恢复失败;`version!=1` 抛异常的现有策略意味着"新版本读旧检查点"必须永远成立(只增不改语义),否则要么丢弃(version 门),要么崩(UICatch 不全时)。

**缓解**:(a) v3 内 version 升 2 时 fromJson 必须接受 1 和 2;(b) 新字段全部可选;(c) 迁移窗口期保留 v1 写入开关;(d) task_recovery_test.dart 3 例 + agent_core_test/models_test 的 checkpoint 用例作回归闸门。

---

## R4. Riverpod Provider 初始化顺序(可能性:中 × 影响:中)

实测的图(构造期即读 prefs/平台通道):

- `main.dart:9-16`:ensureInitialized → ensureSemantics → `_installCrashLogging()`(SharedPreferences.getInstance 后挂 CrashLogStore,**失败不得阻塞启动**,main.dart:20-28)→ runApp(ProviderScope)。
- `app.dart:10` themeModeProvider;五个 Tab 页均为 Consumer。
- `chat_session.dart:1565-1625`:workspaceProvider → workspaceAuthorizedProvider → workspaceManagerProvider → approvalQueueProvider/taskHistoryProvider → conversationImageStoreProvider → chatGatewayOverrideProvider → **memoryStoreProvider**(:1622,失败回 null 的降级语义)→ chatSessionProvider。
- `crashLogProvider`(crash_log_store.dart:169)、`settingsStoreProvider`(settings_store.dart:577)、`usageStatsProvider`(usage_stats.dart:215)均为 FutureProvider,首读时才实例化。
- 交叉消费:chatSession 内部 read memoryStoreProvider/crashLogProvider/usageStatsProvider(chat_session.dart:556-561,758,788);plugin_repo.dart:168 与 scheduled_tasks.dart:517 `ref.watch(settingsStoreProvider.future)`——**settingsStore 未就绪时这两处挂起**;hermes_provider.dart:89-96 watch workspaceProvider+workspaceManagerProvider+settingsStoreProvider。

风险:v3 引入 lib/domain、lib/agent/brain 后若新 provider 依赖链倒置(如 Brain 先于 settingsStore 构建并读模型配置),启动路径会出现静默挂起或 null 降级扩大。

**缓解**:保持"FutureProvider 惰性 + watch .future"约定;新增 provider 必须声明依赖并写一个装配测试(现缺——见 TEST_COVERAGE_MAP.md 空洞表 dsh_provider/hermes_provider 行)。

---

## R5. Windows 非 ASCII 路径构建约束(可能性:高(在本机) × 影响:中,仅发布线)

证据:PROJECT_STATUS.md:41 与 :46-50 —— "release AOT 需经 `subst X:` 盘符路径构建";AOT 快照器不兼容非 ASCII 路径;gradle 走腾讯镜像、`android.overridePathCheck=true`+`kotlin.incremental=false` 解决 AGP/Kotlin 兼容。
本机现实:仓库在 `I:\电脑手机agnet制作\shelly-hermes-release`(非 ASCII);`I:\shelly-ascii\flutter` 存在但为项目镜像目录(bin/ 不全,**不是** Flutter SDK 副本)——"ASCII 镜像"实际靠 `subst` 盘符 + ASCII 工作树达成,而非 `I:/shelly-asciiflutter` 这样的现成 SDK。

风险:v3 若调整目录结构/添加生成代码,本机 release 构建流程(subst→build→subst /D)与 CI(linux)可能出现"CI 绿、本机发布红"。

**缓解**:发布脚本化(SUBST 步骤入 release 脚本);任何路径相关改动先在 subst 盘符下跑一次 assembleDebug 冒烟。

---

## R6. 已知时序 flake(可能性:中 × 影响:低,但会污染信号)

1. steering FIFO 满负载排空(test/state/steering_test.dart:142,完成观察者逐条出队,真实异步链)。
2. bridge dashboard 重绘节流墙钟断言(test/core/mcp/bridge_dashboard_test.dart:293-324,140ms/500ms 硬 sleep)。

风险:迁移期间大改并发代码时,这两个会间歇性红,淹没真实回归信号。**缓解**:每阶段闸门红时先单跑这两文件确认是否 flake;PHASE 早期(见迁移计划 P2)顺手注入调度器消雷。

---

## R7. features/ 与 state/ 内部实现的耦合(可能性:高 × 影响:中)

`grep "import '../../state"` 全量 33 处,features 层没有自己的 provider 边界,而是直接消费 state 类与单例 store:

| features 文件 | 直接 import 的 state 模块 |
| --- | --- |
| features/approval/approval_sheet.dart:11 | state/chat_session.dart |
| features/capabilities/capabilities_page.dart:13-16 | state/chat_session.dart、dsh_provider.dart、plugin_repo.dart、settings_store.dart |
| features/chat/chat_page.dart:25-28 | chat_session.dart、conversation_export.dart、dsh_provider.dart、settings_store.dart |
| features/chat/conversation_actions.dart:5-6 | chat_session.dart、settings_store.dart |
| features/chat/in_chat_search.dart:4 | chat_session.dart |
| features/chat/model_picker_sheet.dart:8 | settings_store.dart |
| features/history/history_page.dart:10-12 | chat_session.dart、conversation_search.dart、settings_store.dart |
| features/memory/memory_page.dart:16-19 | hermes_provider.dart、chat_session.dart、memory_maintenance.dart、settings_store.dart |
| features/memory/memory_settings_page.dart:7 | settings_store.dart |
| features/profile/profile_editor_sheet.dart:6 | settings_store.dart |
| features/profile/profile_page.dart:18-24 | chat_session.dart(show)、lan_companion.dart、settings_store.dart、update_check.dart、usage_stats.dart |
| features/shell/home_shell.dart:9-12 | chat_session.dart、memory_maintenance.dart、scheduled_tasks.dart、settings_store.dart |
| features/tasks/tasks_page.dart:7-8 | chat_session.dart、scheduled_tasks.dart |

深层耦合点:features 大量 `ref.read(settingsStoreProvider).valueOrNull?.loadXxx()` 直调 **store 类方法**(如 model_picker_sheet.dart:99,153,183;capabilities_page.dart:562-563,965;memory_page.dart:166)——即 UI 摸到了存储实现,而不只是状态。

风险:v3 想把 state 拆进 lib/domain 时,33 处 import + 直调 store 方法会在搬运瞬间全断。**这正是控制器评审决定"3.0 不动目录、只加 facade 导出"的依据**。

**缓解**:见 V3_MIGRATION_PLAN.md——3.0 期 state/* 原地保留并新增 facade 文件导出;3.1 物理搬迁用 `dart fix` 级别的机械替换 + 全量 648 测试兜底。

---

## 风险汇总矩阵

| # | 风险 | 可能性 | 影响 | 首要缓解 |
| --- | --- | --- | --- | --- |
| R1 | 32 个 shelly.* prefs 键在升级中丢失 | 高(若不做双读) | 高 | 键清单进验收;读旧写新 |
| R2 | recitation 尾追回归 → 缓存全失配 | 中 | 高 | 5 组缓存纪律测试入每阶段闸门 |
| R3 | checkpoint version 门拒绝旧档 | 中 | 中高 | version 兼容读策略 |
| R4 | Provider 依赖倒置致启动挂起 | 中 | 中 | 装配测试 + 惰性约定 |
| R5 | 非 ASCII 路径 release 构建破裂 | 高(本机) | 中 | subst 脚本化冒烟 |
| R6 | 两处时序 flake 污染信号 | 中 | 低 | 单跑甄别 + 注入时钟 |
| R7 | features→state 33 处直连 | 高 | 中 | facade 导出,3.1 再搬 |
