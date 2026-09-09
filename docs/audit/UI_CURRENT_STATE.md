# Shelly Hermes UI 现状地图(PHASE 0 审计 · Worktree B-3)

> 审计对象:`flutter/lib/**`(基线 commit `5c46be2`,PHASE 54)。本文盘点五 Tab 页的 widget 结构与所 watch 的 provider、导航(IndexedStack + tabIndexProvider + 深链)、主题体系、动画现状,并给出 v3 每个界面的处置结论(ADD / EVOLVE)。所有引用 `文件:行号`(相对 `flutter/`)。

## 1. 导航骨架(HomeShell)

- **五 Tab 定义**:`lib/features/shell/home_shell.dart:32-38`——`ChatPage / TasksPage / HistoryPage / CapabilitiesPage / ProfilePage`,底部 `NavigationBar` 五个目的地「对话/任务/历史/能力/我的」(`:196-222`)。
- **tabIndexProvider**:`StateProvider<int>`(`home_shell.dart:22`),全局单源;跨页驱动 Tab(如历史→对话恢复)与深链都写它。
- **IndexedStack**:`body` 为 `IndexedStack(index, children: _pages)`(`home_shell.dart:189`),保证各 Tab 滚动/流式状态在切换间存活;外层包 `AnimatedSwitcher`(150ms fade,`AppMotion.fast`,`:179-186`)给切换加淡入。注意:`IndexedStack` 同时构建全部五页(非懒加载),首页体积随页数线性增长。
- **?tab=N 深链**(仅 web):initState 解析 `Uri.base.queryParameters['tab']` 并置 tabIndexProvider(`home_shell.dart:72-79`)。
- **Shell 级副作用挂载**:initState 里武装定时任务 ticker(`:63,135-153`)、注册桌面小组件桥(`:64,83-86`)、后台通知 catch-up(跳任务 Tab,`:65,89-91`)、每日记忆整理(`:69,124-133`);`didChangeAppLifecycleState` resumed 时重新 catch-up + 整理(`:107-118`);`ref.listen(scheduledTasksRevisionProvider)` 重建 ticker、`ref.listen(settingsStoreProvider)` 推送小组件快照(`:159-174`)。

## 2. 五 Tab 逐一盘点

### 2.1 对话(ChatPage)— lib/features/chat/chat_page.dart(2369 行,最大单文件)

- **Provider**:`chatSessionProvider`(核心,`chat_page.dart:526`)、`settingsStoreProvider`(`:527`,attach 到 session `:531-533`,并派生 demoMode `:535-539`)、`workspaceAuthorizedProvider`(`:540`)、`dshToolsProvider`(`:634`,插件工具名集合)、`approvalQueueProvider`(`:552`,弹出审批 Sheet `:552-562`)、`chatSessionProvider` 监听触发回底(`:568-571`)。
- **结构**(`build`,`:525-677`):`_Header`(标题/新会话/分享/搜索,`:679`)+ `_ModelChip`(`:800`,watch settingsStore)→ `_WorkspaceBanner`(SAF 未授权,`:1087`)→ `_DemoBanner`(`:1144`)→ `InChatSearchBar`(会话内搜索,`:585-593`)→ 主体 `_Greeting`(空态建议,`:1196`)或 `_Transcript`(`:1300`,内含 `_UserBubble :1452` / `_AssistantMessage :1602` / `_ErrorBubble :1900` / `_NoticePill :1400` / `_StreamingCursor :1863`)→ `_ContextMeter`(PHASE 52 上下文用量条,`:1942`,仅 `inputTokens>0` 时出现 `:649-651`)→ `_Composer`(`:2001`,含 `_QueuedMessagesBar :2332` steering 队列 chips、附件图片/文件条、语音按钮 `_DictateButton :2239`、停止按钮 `_StopButton :2270`)。
- **会话操作**:`_SessionSheet`(`:863`,历史会话列表/切换/置顶/删除,复用 `conversation_actions.dart`)+ `model_picker_sheet.dart` + `regenerateLast`/`editAndResend` 长按菜单(`:410-424`)。
- **审批 UI**:`showModalBottomSheet(ApprovalSheet)` 非可-dismiss、不可拖拽(`:555-562`),由 approvalQueue 驱动。

### 2.2 任务(TasksPage)— lib/features/tasks/tasks_page.dart

- **Provider**:`chatSessionProvider`(`tasks_page.dart:103`,当前活动任务)、`taskHistoryProvider`(`:104`,状态记录,cap 50 `chat_session.dart:1593-1595`)、`scheduledTasksRevisionProvider`(`:107`,变更计数触发重载)、`scheduledTaskStoreProvider`(`:109`)。
- **结构**:空态 `EmptyState`(新建定时任务 CTA,`:120-127`)或 ListView:活动任务卡 `_ActiveTaskCard`(`:638`,含 `_StatusRow :705` 渲染 TaskState 十一态,`lib/core/task_queue.dart:14-26`)、「定时任务」区头 + `_ScheduledTaskCard` 列表(`:252`,展开看结果/启停/编辑/删除)+「状态记录」`_StatusRow` 最近 20 条(`:169-177`)。创建/编辑走 `_ScheduledTaskDialog`(`:488`)。
- 变更后 `_bumpRevision()`(`:28-32`)驱动 shell 重臂 ticker。

### 2.3 历史(HistoryPage)— lib/features/history/history_page.dart

- **Provider**:仅 `settingsStoreProvider`(`history_page.dart:65`);列表 = `sortConversations(store.loadConversations())`;搜索 = `searchConversations(store, query)`(300ms debounce,`:27-58`,实现在 `lib/state/conversation_search.dart`);中断任务横幅 = `TaskRecovery().scan(store).firstOrNull`(`:91-95`)。
- **结构**:AppBar 内嵌切换的搜索框/标题(`:83-129`)+ `RefreshIndicator + ListView.builder`:首行可为 `_InterruptedBanner`(`:210`,从 checkpoint 重跑或丢弃)、其余 `_ConversationTile`(`:303`)包 **`StaggerIn`** 入场(`:170`);空态两种 `EmptyState`(`:132-150`)。清空列表仅删 summary 不动 checkpoint(`:186-205`)。

### 2.4 能力(CapabilitiesPage)— lib/features/capabilities/capabilities_page.dart

- **Provider**:`workspaceFileCountProvider`(`:33`)、`dshRegistryProvider`(`:179,331`)、`dshTrustProvider`(`:332`)、`workspaceAuthorizedProvider`(`:190`)、`settingsStoreProvider`(`:689`,MCP 配置)、`pluginRepoProvider`(`:1171`)。
- **结构**(ConsumerWidget + ListView,`build :32-113`):「工作区工具」`_ToolTile` 列表(渲染 `WorkspaceToolRegistry.workspaceSpecs` + 实际生效的 `ToolPolicy.standard` 等级,`:37-49`)→ `_PluginSection`(DSH 生命周期,`:119`)→ `_McpSection`(HTTP 连接器 CRUD + `_GuardWarningCard` 供应链指纹告警,`:550,833`)→ `_BridgeSection`(桌面桥,`:948`)→ `_PluginRepoSection`(插件预设目录,`:1116`)→ `_EnvironmentSection`(`:1323`)→ `_TrustSection`(信任总览,`:325`)→ 底部策略说明卡(`:87-113`)。

### 2.5 我的(ProfilePage)— lib/features/profile/profile_page.dart

- **Provider**:`settingsStoreProvider`(`:271`)、`themeModeProvider`(`:286`)、`updateCheckProvider`(`:287`)、`usageStatsProvider`(`:643`)、`crashLogProvider`(`:906`,诊断卡内)、`lanCompanionProvider`(`:1160`)、`tabIndexProvider` 监听(`:275-280`:切到本 Tab 时 invalidate usage/crash,解决"跨页写入不刷新")。
- **结构**(ListView 区块,`:304-651`):Agent 档案卡(选择/新建/编辑,`showProfileEditor` → `profile_editor_sheet.dart`)+ Provider 预设 chips + 模型三字段(BaseUrl/API Key/模型)+ 获取模型列表/测试连接 + 采样参数入口 → 「外观」(`:540`,themeMode 切换)→ 「语音」(`:575`,TTS)→ 「局域网伴侣」`_LanCompanionCard`(`:607`)→ 「记忆」(`:610`,入口 `MemoryPage`/`memory_settings_page.dart`)→ 「用量统计」`_UsageCard`(`:643`)→ 「诊断」`_DiagnosticsCard`(`:646`)→ 「关于」+ `_UpdateCard`(`:648,240`)。

## 3. 主题体系

- **入口**:`lib/app.dart:27-34`——`MaterialApp(theme: buildShellyTheme(light), darkTheme: buildShellyTheme(dark), themeMode: themeModeProvider)`;`themeModeProvider`(`app.dart:10-19`)默认跟系统,web 支持 **`?theme=dark|light` 深链**。
- **buildShellyTheme**(`lib/design/theme.dart:10-185`):按 brightness 解析 `AppSemanticColors`(semantic token),装配 M3 ColorScheme(`primary=semantic.accent`:**浅色模式 accent=墨色 ink,深色模式 accent=近白**,tokens.dart:165,182)、AppBar/NavigationBar/Card/Button/Input/Switch/Chip/BottomSheet/Dialog 全套组件主题;卡片 0 elevation + hairline 描边(`:79-88`)。
- **PHASE 49 ripple 修复**:水波纹颜色按亮度区分——浅色画布用墨色低透明 ripple、深色画布用白色(墨色 ripple 在深色下不可见),`theme.dart:172-179`(`splashColor/highlightColor` 双分支),配合全局 `InkSparkle.splashFactory`(`:36`)。
- **Token 三件套**(`lib/design/tokens.dart`):
  - `AppColors`(`:10-59`):品牌渐变 brandBlue→brandViolet(PHASE 44 起降级为点缀)、ink accent、状态色双套(浅深模式各一组)、`cardShadow` 柔和环境影(仅浅色使用)。
  - `AppSpacing`(`:61-68`,4/8/12/16/24/32)与 `AppRadius`(`:73-79`,sm8/md12/lg18/xl24/pill)。
  - `AppMotion`(`:83-108`):fast 150ms / normal 250ms / slow 350ms、`emphasized` 位移曲线、easeOut/easeIn、stagger 40ms×最多 8 项。
  - `AppSemanticColors`(`:113-245`):ThemeExtension,`dark`/`light` 两份静态定义(`:153,170`),UI 一律经 `Theme.of(context).extension<AppSemanticColors>()!` 取色,自身带 copyWith/lerp。
- 组件库:`lib/design/components/`(buttons/code_block/empty_state/gradient_avatar/markdown_text/risk_chip/skeleton/tool_card)。

## 4. 动画现状

| 组件 | 位置 | 说明 | 现用页面 |
|---|---|---|---|
| `FadeSlideIn` | `lib/design/components/motion.dart:8-69` | fade+8px 上浮,`AppMotion.normal`+emphasized | 助手消息(chat_page.dart:1634) |
| `StaggerIn` | `motion.dart:74-88` | 40ms×index 级联,封顶 8 项 | 历史列表(history_page.dart:170) |
| `TypingIndicator` | `motion.dart:93-157` | 三点脉冲(唯一允许的循环动画) | 流式等待(chat_page.dart:1644,1656) |
| `PressableScale` | `lib/design/components/buttons.dart:7-36` | 按下缩至 0.97,150ms | 主/次按钮与 hero 卡 |
| `AnimatedSwitcher`(fade) | `home_shell.dart:179-186` | Tab 切换淡入 | Shell |
| `_StreamingCursor` | `chat_page.dart:1863-1898` | 流式光标 | 助手流式行 |

纪律:只动 transform/opacity、入场 ease-out、密集区克制(tokens.dart:81-82 注释)。**现状问题**:FadeSlideIn/StaggerIn 覆盖率低(仅 2 处引用),`IndexedStack` 首帧全量构建未配骨架屏(骨架组件 `skeleton.dart` 存在但五 Tab 未接入),任务/能力/我的三页无入场动画。

## 5. v3 处置结论(逐界面)

| 界面 | 结论 | 一句话理由 |
|---|---|---|
| **Home(启动首页)** | **ADD**(新增) | 现状以 ChatPage 兼任首页,无独立 Home;v3 的 Mission 体系需要独立的任务总览首屏,建议新增而非改造 `_Greeting`(chat_page.dart:1196) |
| **Composer(输入区)** | **ADD**(重构级新增) | 现 `_Composer`(chat_page.dart:2001-2213)已叠 steering 队列/附件/语音/停止多职责且为 StatelessWidget 直连回调;v3 的编排式输入(计划确认/任务预览)需要独立 Composer 模块重新设计 |
| **Mission Timeline(任务时间线)** | **ADD**(新增) | 现 TasksPage 只有平铺状态记录 `_StatusRow`(tasks_page.dart:705),无轮次/工具粒度时间线;Mission 模型(Step=round、Action=tool call)需要全新时间线组件,事件源可复用 AgentEvent 流(agent_core.dart:150-154 的 emit 缝隙) |
| **ChatPage(对话页)** | **EVOLVE** | 链路最重(2369 行单文件),但 transcript/审批/搜索/再生成语义稳定;保留骨架,把 `_Composer`、`_SessionSheet` 拆出,evolve 为 Mission 感知的视图 |
| **TasksPage(任务页)** | **EVOLVE** | 结构可沿用,数据源需从 `taskHistoryProvider` 平铺日志升级为 Mission/Step 结构,卡片语义跟随升级 |
| **HistoryPage(历史页)** | **EVOLVE** | 检索/置顶/中断恢复交互成熟;v3 数据源扩为对话+Mission 归档,列表卡片进化,逻辑基本平移 |
| **CapabilitiesPage(能力页)** | **EVOLVE** | 分区已多(插件/MCP/桥/预设/环境/信任,`capabilities_page.dart:44-113`),v3 新增能力家族时按既有分区模式扩展,需收紧为分节懒加载(现整页 ListView 一次构建) |
| **ProfilePage(我的页)** | **EVOLVE** | 设置项聚合页,新增 Brain/记忆 v3 设置沿用 `_SectionHeader`+卡片区模式即可;`tabIndexProvider` 监听刷新(`:275-280`)的手法应改为响应式 provider |
| **ApprovalSheet(审批面板)** | **EVOLVE** | 现 hunk 级审批+diff 展示+always-allow 已完备(approval_sheet.dart:25-70,209-220);v3 扩展为多类确认(Mission 计划批准、批量操作)需在此 Sheet 之上泛化决策卡(`_DecisionCard :236`) |
| **主题/动画体系** | **保留(EVOLVE 范围外)** | token 三件套+semantic colors 结构健康,新界面直接消费,不推倒 |

**横切注意**:五 Tab 全部直接 `Theme.of(context).extension<AppSemanticColors>()!` 取色(强解包,测试环境必须先注入主题);`IndexedStack` 常驻五页,新增 Home 后为六页,建议 v3 评估懒加载(AutomaticKeepAlive+条件构建)以控制首帧。
