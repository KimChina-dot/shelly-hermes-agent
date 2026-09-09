# Shelly Hermes 数据模型地图(PHASE 0 审计 · Worktree B-1)

> 审计对象:`flutter/lib/**`(基线 commit `5c46be2 feat(chat): interrupt-and-steer + in-conversation search (PHASE 54) (#48)`)。
> 本文档盘点**每一个持久化数据形状**:存储后端、prefs key、schema、写入/读取位置,以及 v3 迁移时改形状会发生什么。所有结论均来自逐行读码,引用格式 `文件:行号`(相对 `flutter/`)。

## 0. 持久化底座总览

| 后端 | 说明 | 代码位置 |
|---|---|---|
| `SharedPreferences`(Flutter 端,单个 prefs 文件) | 几乎全部业务数据的落点,全部为 `String`(JSON)或 `bool`/`int` | `lib/state/settings_store.dart:227`(`SettingsStore`)、各 Store 类 |
| AndroidKeyStore(MethodChannel `dev.shelly/secure_store`) | 模型 API Key 的 Android 安全存储 | `lib/platform/secure_box.dart:16-27` |
| `shelly.secure.*` prefs 前缀 | SecureBox 在非 Android 宿主(web 开发台)上的降级实现 | `lib/platform/secure_box.dart:30-50` |
| 原生 SharedPreferences 文件 `shelly_native` | WorkManager 唤醒用的定时任务镜像,由 Dart 经 MethodChannel `dev.shelly/bg_tasks` 推送、原生写入 | `lib/core/platform/background_tasks.dart:12-17,84-88`、`flutter/android/app/src/main/kotlin/dev/shelly/shelly_hermes/BackgroundTaskWorker.kt:110-111` |
| 磁盘临时目录(`<tmp>/shelly_images`) | 会话附件图片落盘,checkpoint 里只存文件路径 | `lib/state/chat_session.dart:1600-1610`、`lib/platform/conversation_images.dart` |

通用容错模式(对所有 key 一致):读取时 `try { jsonDecode(...) } on FormatException { return 空/默认 }`——**schema 损坏静默清空而不是崩溃**。这意味着 v3 改 schema 的最坏结果通常是"旧数据被丢弃",而不是"应用崩溃";但也是"静默丢用户数据",必须在迁移计划里显式处理(见 §4)。

---

## 1. 会话与检查点(核心链路)

### 1.1 ChatSessionState / ChatEntry — 仅内存,不落盘

- 定义:`lib/state/chat_session.dart:108-165`(`ChatSessionState`)、`:52-104`(`sealed ChatEntry`:UserEntry/AssistantEntry/ToolEntry/ErrorEntry/NoticeEntry)。
- 归属:`chatSessionProvider`(`lib/state/chat_session.dart:1630-1633`,StateNotifier)。
- **不直接持久化**。持久化真相源是 AgentCheckpoint(§1.2);UI 回放由 `_entriesFromCheckpoint`(`lib/state/chat_session.dart:622-658`)从 checkpoint 重建 entries(tool 消息按 `toolCallId` 对齐回 ToolEntry)。
- `queuedMessages`(PHASE 51 steering 队列,cap=5,`:177`)同样是内存态,`newConversation`/`switchTo` 时清空(`:391-393`、`:407`)。

**v3 风险:低(无持久化形状)**。但注意 ChatEntry 的 `id` 是进程级自增 `e-N`(`:53-57`),checkpoint 恢复后 id 会重排——任何 v3 新功能若把 entry id 当稳定句柄(如 TTS 说话中的 `speakingEntryId`)必须继续接受 id 重排。

### 1.2 AgentCheckpoint — `shelly.checkpoint.<conversationId>`

- 定义:`lib/core/models.dart:206-265`。字段:`messages: List<AgentMessage>`、`round`、`consumedTokens`、`toolCalls`、`pendingToolCalls`。
- 信封:`{'version': 1, ...}`(`models.dart:222-229`);`fromJson` 对 `version != 1` **抛 FormatException**(`models.dart:231-235`)→ `SettingsStore.loadCheckpoint` 捕获后返回 null(`lib/state/settings_store.dart:394-402`)→ 该会话在历史页点开时静默失败(`switchTo` 返回 false,`lib/state/chat_session.dart:398-410`)。
- 写入:`_StoreCheckpoints.save`(`lib/state/chat_session.dart:1467-1478`)→ `SettingsStore.saveCheckpoint`(`lib/state/settings_store.dart:404-405`)。AgentCore 在一轮内多次落盘:approval 前后、执行前后、工具消息追加后(`lib/core/agent_core.dart:210-257`)。
- 删除:`deleteConversation` 同时移除 summary 和 checkpoint(`lib/state/settings_store.dart:351-356`)。
- 内嵌形状:
  - `AgentMessage`(`models.dart:49-121`):`role`(枚举名,`byName` 反序列化,**未知角色名会抛异常** `models.dart:84`)、`content`、`toolCallId?`、`toolCalls[]`、`images[]`(data:URL 或磁盘路径,`_persistImages` 把 data:URL 换成文件路径,`lib/state/chat_session.dart:1145-1183`)、`textFiles[]`(附件全文进 checkpoint,`models.dart:9-10,17-23`)。
  - `ToolCall`(`models.dart:123-151`):`id/name/argumentsJson`,字段均为必填强转(`models.dart:133-137`),缺字段抛异常。
  - `PendingToolCall`(`models.dart:180-204`):`{call, stage}`,stage ∈ awaitingApproval/awaitingExecution/running(`models.dart:204`)。
- 恢复语义:`TaskRecovery.scan` 需要 record+checkpoint 双证据(`lib/core/task_recovery.dart:71-77`);regeneration 用重置预算的合成 checkpoint(`round:0, consumedTokens:0, toolCalls:0`,`lib/state/chat_session.dart:481-488`)。

**v3 风险:最高**。
1. `version:1` 硬校验意味着 v3 一旦升级信封版本,所有现存会话 checkpoint 一次全灭(version≠1 → FormatException → load 返回 null → 历史全丢)。迁移必须写 `version<=N` 的兼容读法。
2. `MessageRole.values.byName` 无兜底:`role` 枚举改名/删除 = 旧 checkpoint 解码崩溃(被 FormatException 捕获的前提是异常类型对得上;`byName` 抛的是 `ArgumentError`,**不会被 `on FormatException` 捕获**——`AgentCheckpoint.decode` 在 `loadCheckpoint` 里只捕获 FormatException,`ArgumentError` 会向上炸到 `switchTo`。这是现存的潜在崩溃点,v3 动枚举前必须先补兜底)。
3. `toolCalls`/`pendingToolCalls` 强转无 `??` 兜底(`models.dart:240-242`),旧记录缺键同样抛错。
4. 附件图片已从 data:URL 迁到磁盘路径;v3 若改图片存储位置,旧 checkpoint 里的路径悬空(`_entriesFromCheckpoint` 会展示死路径)。

### 1.3 TaskRecoveryRecord — `shelly.task.active`

- 定义:`lib/core/task_recovery.dart:13-43`(`{conversationId, taskId, startedAt}` ISO8601)。
- 写入:任务启动时 `store.saveActiveTask`(`lib/state/chat_session.dart:535-539`);完成/失败时 `clearActiveTask`(`:575`、`:586`)。
- 读取:`interruptedTask()`/`recoverInterruptedTask()`(`lib/state/chat_session.dart:353-377`)。

**v3 风险:低**。单记录、可丢弃;形状变化最多让"中断恢复"失效一次。

---

## 2. 会话列表与配置(SettingsStore)

### 2.1 ConversationSummary — `shelly.conversations`

- 定义:`lib/state/settings_store.dart:106-144`。字段:`id/title/updatedAt(ISO8601)/messageCount/pinned/modelId?`。
- 读写:`loadConversations`/`saveConversations`(`settings_store.dart:332-348`);每次任务完成整体重写,新会话插最前、**cap 100 条**(`lib/state/chat_session.dart:668-688`,`take(100)`);排序=置顶优先+更新时间(`settings_store.dart:147-153`)。
- 变更操作:rename/pin(`settings_store.dart:358-391`)。

**v3 风险:中**。`fromJson` 的 `id/title/updatedAt/messageCount` 是硬必填强转(`settings_store.dart:135-143`),缺键抛 FormatException → **整个列表被清空**。新增可选字段安全;改名/移除必填字段 = 历史列表全灭(checkpoint 还在,列表重建不出来)。

### 2.2 ModelConfig — `shelly.model.config`(主)/ `shelly.model.aux`(辅)/ `shelly.model.aux.enabled`

- 定义:`lib/state/settings_store.dart:17-103`。字段:`baseUrl/apiKey/model/contextWindow/webSearchEnabled/temperature?/topP?/maxTokens?`(采样三参数为 PHASE 51 增量,`toJson` 按条件写入 `:75-84`,`fromJson` 宽松解析 `:86-95`)。
- 写入:`saveModelConfig`(`settings_store.dart:267-278`)——有 SecureBox 时 **apiKey 从 prefs JSON 剥离**,写进 KeyStore(key `model.apiKey`,`settings_store.dart:240,273`),prefs 里只留空 key 的副本;读取时从内存缓存拼回(`:255-265`),`restoreApiKey` 兼容旧"key 在 JSON 里"的记录(`:282-298`)。
- 辅助模型:`loadAuxModelConfig`(`:305-316`),key 可空、运行时继承主 key(`lib/state/chat_session.dart:1307-1310`);开关 `auxEnabled`(`:320-323`)。

**v3 风险:低-中**。字段全宽松解析,加字段安全;但 v3 若把"单端点"改成"多端点/多 key",要注意 SecureBox 里 `model.apiKey` 这个历史键的读回逻辑(`:282-298` 的 legacy 迁移分支要保留)。`contextWindow>0 才写盘`的条件序列化意味着 0/缺省语义必须保持一致。

### 2.3 AgentProfile — `shelly.agent.profiles` + `shelly.agent.profile.active`

- 定义:`lib/core/agent_profile.dart:6-99`(`{id,name,systemPrompt,autoCapture,maxRounds,maxToolCalls,providerId}`),内建三预设(`:101-124`),`isValid` 校验轮次 1-200/工具 1-500(`:32-38`)。
- 读写:`loadProfiles`(空/损坏回退预设,`lib/state/settings_store.dart:409-422`)、`saveActiveProfileId`(`:539-543`)、`activeProfile()` 兜底第一个预设(`:546-553`)。

**v3 风险:低**。宽松解析+预设兜底;坏档位被 `where((p) => p.isValid)` 过滤。

### 2.4 MemorySettings — `shelly.memory.settings`

- 定义:`lib/core/hermes/memory_settings.dart:5-91`。7 个 int 旋钮(maxLedgerTokens/activeDays/coolingDays/frequencyFloor/maxAutoEntries/recallEntries/recallTokens),`fromJson` 带范围 clamp(`:66-90`)。

**v3 风险:极低**。类型不对回默认、越界 clamp,设计上就是迁移安全的。

---

## 3. 记忆 / 崩溃 / 用量 / 定时

### 3.1 MemoryFact — `shelly.memory.facts`

- 定义:`lib/core/memory/memory_store.dart:23-84`。字段:`id/text/createdAt(ISO8601)/sourceConversationId?/tier`(tier ∈ archival/recall/core,`memory_store.dart:8-18`)。
- 存储:`MemoryStore.storageKey = 'shelly.memory.facts'`(`memory_store.dart:134`),单 JSON 数组,**cap 200 条,最新优先,core 豁免年龄裁剪**(`_cap`,`:314-329`)。
- 写入:`addFacts`(去重按规范化文本,`:166-192`)、`promote`(改 tier,`:198-213`)、导入导出 `{version:1, exportedAt, count, facts}` 信封(`:227-306`)。
- tier 解码宽容:未知/缺 tier 落回 recall(`:64-71`)。

**v3 风险:低**。这是全库迁移健壮性最好的 schema:所有字段有 `??` 兜底,tier 宽容解码,导入信封已带版本号。v3 若扩 tier 枚举,只需保持 `_tierFromName` 的宽容模式;若删除 tier 或改 id 生成规则(`m-<n>-<ms>`,`:183`),去重与合并逻辑不受影响。

### 3.2 记忆维护三键:`shelly.memory.maintenance.lastRun` / `shelly.memory.recallAgeDays` / `shelly.memory.archivalCap`

- `lib/state/memory_maintenance.dart:37-43`。lastRun 为 epoch millis int(`:70`),另两个为 int 配置。

**v3 风险:极低**。独立 int,丢了只是多做/少做一次整理。

### 3.3 CrashEntry — `shelly.crash.logs`

- 定义:`lib/core/crash/crash_log_store.dart:12-42`。字段:`at(ISO8601)/context('flutter'|'platform')/error/stack`(栈截断 2000 字符,`:60`)。
- 存储:key `shelly.crash.logs`(`:54`),**newest-first**,cap 50(`:57`);`record` 在 main.dart 启动时挂钩 FlutterError/PlatformDispatcher(`lib/main.dart:22-29`、`crash_log_store.dart:127-166`)。

**v3 风险:极低**。诊断数据,全兜底解析,丢了无感。

### 3.4 UsageEntry — `shelly.usage.stats`

- 定义:`lib/state/usage_stats.dart:10-62`。字段:`modelId/promptTokens/completionTokens/cachedTokens/at(ISO8601)`。`cachedTokens` 为 PHASE 46 增量,旧记录缺键读 0(`:44`)。
- 存储:key `shelly.usage.stats`(`:119`),**保留 30 天 + cap 1000**(`:122,125,199-205`)。写入链:每轮 `recordUsage`(`lib/state/chat_session.dart:751-770`)→ `UsageStatsStore.recordUsage`(`usage_stats.dart:131-148`)。

**v3 风险:低**。全兜底;聚合按 modelId 字符串分组(`:166-186`),v3 若改模型标识语法只影响历史分组口径。

### 3.5 ScheduledTask — `shelly.sched.tasks`

- 定义:`lib/state/scheduled_tasks.dart:28-162`。字段:`id/prompt/at(epoch millis!)/repeat(once|daily|weekly)/enabled/lastRunAt?(epoch)/result?/status(pending|done|failed)`。注意 `at` 用 epoch 而非 ISO8601(与 usage/memory 不同,`:114`)。
- 存储:key `shelly.sched.tasks`(`:174`),读出后按 `at` 排序(`:188`);`recordRun` 记录结果并把重复任务推到下一次(`:276-301`)。
- 执行器:应用内 tick(`SchedulerService.tick`,`:379-419`)+ 每轮重建网关(`settingsBackedRunner`,`:329-352`)。

**v3 风险:中**。`repeat`/`status` 用 `asNameMap()[...] ?? 默认`(`:131-132,140-141`),宽容;`prompt`/`at` 宽松;整体安全。但 v3 若引入"任务引用某个模型/agent 配置"之类的关联字段,要同时考虑与原生镜像(§5.1)的同步。

---

## 4. MCP / 插件 / 桥接

### 4.1 McpServerConfig — `shelly.mcp.servers`

- 定义:`lib/core/mcp/mcp_client.dart:10-55`。字段:`id/name/url/token?/toolFingerprint?`(PHASE 46 供应链指纹)。
- 存储:`lib/state/settings_store.dart:447-463`(`List<McpServerConfig>` JSON 数组)。**token 明文存 prefs**。
- 指纹审批表另存:`shelly.mcp.toolprints`(`settings_store.dart:249,467-497`,`Map<serverId, sha256>`)。

**v3 风险:中**。`fromJson` 的 `id` 硬必填(`mcp_client.dart:49`)——单条坏记录会让 `loadMcpServers` 的类型过滤(`if entry is Map`)放进来后在其上抛异常……实际上 `McpServerConfig.fromJson` 在 map 内抛出不会被捕获(prefs 层只捕 FormatException),会炸到读取方;v3 动此 schema 需要整表迁移+指纹表同步重算(工具目录变了指纹即失效,用户要重新批准)。

### 4.2 McpStdioServerConfig — `shelly.mcp.stdio`

- 定义:`lib/state/settings_store.dart:181-223`。字段:`id/name/command/args[]/env{}`(插件预设注册的本地 stdio 服务器,命令行要过 JSON 往返)。
- 读写:`settings_store.dart:520-537`。

**v3 风险:中**。`id` 硬必填(`:209`);args/env 有类型过滤兜底。桌面侧能力,v3 若把 stdio 挪进 bridge/沙箱模型,这里要整体重写并与预设目录(`shelly.plugin.installed`)联动。

### 4.3 McpBridgeConfig — `shelly.mcp.bridge`

- 定义:`lib/state/settings_store.dart:162-179`。字段:`baseUrl/token`。
- 读写:`settings_store.dart:501-518`(解析时连 TypeError 都吞了,`:509-513`)。

**v3 风险:低**。两字段结构,几乎不可能破坏。

### 4.4 插件预设安装表 — `shelly.plugin.installed`

- `lib/state/plugin_repo.dart:98`(JSON 字符串数组);写入时同步向 `shelly.mcp.servers` 增删 `preset.<id>` 条目(`mcpEntryId`,`:103`)。
- **注意**:`plugin_repo.dart:75` 出现的 `shelly.db` **不是 prefs key**,是 sqlite 预设插件的 `--db-path` 命令行参数,grep 盘点时不要误计。

**v3 风险:低**。丢了最多要求重装插件;但与 mcp.servers 的双表联动在 v3 改 MCP schema 时要一起迁移。

---

## 5. 其余散键(完整 grep 盘点)

对 `lib/**` 全量 grep `shelly.` 字面量的结果与归属(全部键,无遗漏):

| Key | 类型 | 写入 | 读取 | 用途 |
|---|---|---|---|---|
| `shelly.model.config` | String JSON | `settings_store.dart:269,274-277` | `:255-265` | 主模型端点+采样参数 |
| `shelly.model.aux` | String JSON | `settings_store.dart:315-316` | `:305-313` | 辅助模型(摘要/压缩/记忆抽取) |
| `shelly.model.aux.enabled` | bool | `settings_store.dart:322-323` | `:320` | 轻任务切辅模型开关 |
| `shelly.conversations` | String JSON 数组 | `settings_store.dart:344-348` | `:332-342` | 会话摘要列表(cap100) |
| `shelly.checkpoint.<convId>` | String JSON(动态后缀) | `settings_store.dart:404-405` | `:394-402,355` | 会话检查点(version:1) |
| `shelly.task.active` | String JSON | `settings_store.dart:570-571` | `:559-567` | 后台恢复记录 |
| `shelly.agent.profiles` | String JSON 数组 | `settings_store.dart:424-427` | `:409-422` | Agent 档案 |
| `shelly.agent.profile.active` | String | `settings_store.dart:541-543` | `:539` | 当前档案 id |
| `shelly.memory.settings` | String JSON | `settings_store.dart:442-445` | `:431-440` | 记忆旋钮 |
| `shelly.memory.facts` | String JSON 数组 | `memory_store.dart:331-334` | `:148-159` | 长期记忆事实(cap200) |
| `shelly.memory.maintenance.lastRun` | int | `memory_maintenance.dart:70` | `:67` | 每日整理节流(epoch ms) |
| `shelly.memory.recallAgeDays` | int | (设置页写入,`memory_maintenance.dart:40` 定义) | `:73` | recall 层老化窗口 |
| `shelly.memory.archivalCap` | int | (同上 `:43`) | `:74` | archival 层容量 |
| `shelly.crash.logs` | String JSON 数组 | `crash_log_store.dart:104-107` | `:88-99` | 崩溃日志(cap50,newest-first) |
| `shelly.usage.stats` | String JSON 数组 | `usage_stats.dart:207-210` | `:151-162` | 用量统计(30d/1000 条) |
| `shelly.sched.tasks` | String JSON 数组 | `scheduled_tasks.dart:303-306` | `:181-193` | 定时任务 |
| `shelly.sched.bgstate` | String JSON 数组(原生文件 `shelly_native`) | 原生侧经 MethodChannel `pushState`(`background_tasks.dart:84-88`) | `BackgroundTaskWorker.kt:40,62`(`entry.optLong("at")`) | WorkManager 唤醒镜像 `[{id,at}]` |
| `shelly.mcp.servers` | String JSON 数组 | `settings_store.dart:460-463` | `:447-458` | HTTP MCP 连接器 |
| `shelly.mcp.stdio` | String JSON 数组 | `settings_store.dart:533-537` | `:520-531` | stdio MCP 服务器 |
| `shelly.mcp.bridge` | String JSON | `settings_store.dart:517-518` | `:503-515` | 桌面桥配置 |
| `shelly.mcp.toolprints` | String JSON map | `settings_store.dart:486-497` | `:467-482` | 工具目录指纹审批 |
| `shelly.plugin.installed` | String JSON 数组 | `plugin_repo.dart:99+` | 同文件 | 已装插件预设 id |
| `shelly.tts.enabled` | bool | `settings_store.dart:329-330` | `:327` | 朗读开关 |
| `shelly.lan.enabled` | bool | `lan_companion.dart:26` | `:24` | 局域网伴侣开关 |
| `shelly.lan.token` | String | `lan_companion.dart:34-37` | `:31` | 配对令牌(明文 prefs) |
| `shelly.update.lastcheck` | int | `update_check.dart:74` 定义 | 同文件 | 更新检查节流(epoch ms) |
| `shelly.secure.<key>` | String | `secure_box.dart:36-43` | `:33-35` | SecureBox 非 Android 降级(key=`model.apiKey`) |
| (`shelly.db`) | — | — | — | 非 prefs key;sqlite 插件参数(`plugin_repo.dart:75`) |

---

## 6. v3 迁移风险汇总(按严重度)

1. **`shelly.checkpoint.*`(致命)**:version 硬校验 + `MessageRole.values.byName`/`ToolCall.fromJson` 强转无兜底。v3 若动 AgentMessage/ToolCall/信封版本,**所有历史会话一次性消失,且 role 枚举变更可能以 ArgumentError 形式绕过现有的 FormatException 兜底直接崩溃**(`lib/core/models.dart:84,231-244`、`lib/state/settings_store.dart:397-401`)。必须:兼容多版本读 + 全字段 `??` 兜底 + 迁移器。
2. **`shelly.conversations`(高)**:必填字段强转,单条坏记录 → 整表清空(`settings_store.dart:135-143`)。
3. **`shelly.mcp.servers`(中)**:`id` 硬必填 + 与 `shelly.mcp.toolprints` 指纹联动;token 明文存储,v3 应顺势迁 SecureBox。
4. **`shelly.sched.bgstate`(中)**:活在**原生 prefs 文件** `shelly_native` 里,Dart 端 shared_preferences 的迁移工具看不到它;改键名/schema 必须同步改 Kotlin(`BackgroundTaskWorker.kt:110-111`)。
5. **图片路径悬空(中)**:checkpoint 已存磁盘路径(`<tmp>/shelly_images`),v3 换缓存目录/清理策略 = 旧会话附件失效(`chat_session.dart:1600-1610`)。
6. **低风险层**:`shelly.memory.facts`(宽容解码+版本信封)、`shelly.usage.stats`、`shelly.crash.logs`、`shelly.memory.settings`、profile/aux/tts/lan/update 等单开关键——丢得起、可重建。

**通用守则**:本代码库所有 reader 的兜底只捕 `FormatException`(`on FormatException`);v3 引入任何会抛其他异常类型的解码路径(如 `byName`、硬 cast)都会越过这层防护,迁移代码审查时应把"新解码是否会抛非 FormatException"列为检查项。
