# Changelog

## 3.0.0 (未发布)

v3.0 架构迁移:按 `docs/audit/V3_MIGRATION_PLAN.md` 以增量并行轨推进——新模块全部进新路径
(`lib/domain/`、`lib/agent/brain/`、`lib/capability/`、`lib/skills/`、`lib/core/migration/`),
既有 `lib/core|state|features` 原路径不动,目录大挪移推迟到 3.1。阶段序列与提交号如下
(每阶段独立提交串,`6694556..141cfa5`,#49-#58)。

### 迁移阶段(PHASE 0 → PHASE 14)

- **PHASE 0** 架构审计:docs/audit/ 九文档(架构/模块/依赖/数据模型/Agent 回路/UI/测试覆盖/风险登记/迁移计划)(`6694556`,#49)。
- **PHASE 1** v3 领域模型 + 事件总线:Goal/Mission/Task/Step/Action 只读模型、MissionStore、
  MissionEvent/AgentEventBus;纯增量,零改旧文件(`b8bb189`,#50)。
- **PHASE 2** Mission 桥接:MissionCoordinator 把 task 生命周期桥接到 v3 Mission 域
  (chat_session 挂接发事件),不复制任务状态机(`08064b6`,#51)。
- **PHASE 3** 最小 Brain:intent_router + planner,脚本化可测,不经旁路网关(`e253e15`,#52)。
- **PHASE 4** 统一能力层:Capability/CapabilityRegistry/CapabilityRouter + 信任分
  (trust_score/trust_store),为技能/插件/MCP 提供同一注册面(`68512d8`,#53)。
- **PHASE 5** 技能层:skill_definition/skill_registry + 内置技能(`17518c2`,#54)。
- **PHASE 6** DynamicSkillHost:DSH 插件统一挂为 capability(`ef28daf`,#53 合并流)。
- **PHASE 7** MCP 桥:MCP servers as capabilities,serverIds/specsFor API(`2b05992`,#53 合并流)。
- **PHASE 8** Brain preflight 集成:计划注入(plan seeding)+ 共享 token 预算,
  Brain 调用计入同一 64K 消耗账本;agent_core/chat_session 接线,默认路径行为可回退(`408b63a`,#55)。
- **PHASE 9** 技能激活工具:list_skills/use_skill 上模型工具面(skill_tool_registry),
  模型可自主查用已注册技能(`d20c844`,#56)。
- **PHASE 10** MigrationManager:五段式 backup→validate→migrate→verify→rollback +
  R1 键清单 MigrationKeySpec 校验表;build-only,生产启动串未接线(`22b97a8`,#57)。
- **PHASE 11** eval 扩展:brain 路径场景(plan seeding/bypass/budget/fail-open/recitation
  refresh),eval 场景 11→16,原场景不回归(`141cfa5`,#58)。
- **PHASE 12** ApprovalPort:审批经能力端口解耦,ApprovalBroker implements ApprovalPort,
  approval_sheet 不再直连 core;纯增量零行为变化(`808b24d`,第二波任务提交)。
- **PHASE 13** Mission Timeline:只读任务时间线 UI(列表 + 详情),第 6 个「使命」Tab
  挂入 home_shell,数据只经 MissionStore/MissionCoordinator/事件总线(`a9f4159`,第二波任务提交)。
- **PHASE 14** 文档收账:CHANGELOG 3.0 段 + V3_MIGRATION_PLAN 执行状态段
  (实际阶段↔文档编号映射全表、未落地清单)(`1861474`,第二波任务提交)。
- **PHASE 15** 安全网补测:TEST_COVERAGE_MAP §3 空洞(approval_sheet UI 10 例/task_service/
  dsh_provider/hermes_provider)+ bridge_dashboard 计时可注入消雷(5 连跑无 flake,套件 1:38→1:09)
  (`7a9efe6`,第三波,#62)。
- **PHASE 16** facade 收敛:shelly_facade.dart 聚合 37 库,features 64/65 处 core/state 直连
  import 机械替换,零逻辑改动(`d476e66`,第三波,#63)。
- **PHASE 17** 能力谓词收紧:任务装配期构建真实能力可用集(filesystem/terminal/mcp_<id>/bridge/
  DSH id)驱动 use_skill,PHASE 9 占位退役(`76682c2`,第三波,#64)。
- **PHASE 18** cutover(P8):启动串接入五段式迁移(crash logging 之后、runApp 之前,失败开放 +
  8s 超时 + 崩溃日志留证);三路升级矩阵(v2.2/v2.3/v2.4 档案)与回滚演练入测试(`ad2bdb7`,#65)。
- **PHASE 19** facade 冻结(P14):MODULE_MAP 全行处置(keep 62/wrap 31/move 6)+ V31 搬迁清单
  (6 项 8 步,可执行替换命令)+ 模块头锚点注释;@Deprecated 按实验证据诚实降级(`589c886`,最终波,#66)。
- **PHASE 20** 平台契约回归(P13):全部实存 5 通道契约测试(20 例新増)+ build-smoke.mjs
  构建冒烟(debug APK SHA256 留证)+ CI 可达的 @visibleForTesting 通道钩子(`92be275`,最终波,#67)。
- **PHASE 21** 发布门禁准备(P15):版本四处同步 3.0.0(修复 v2.2 起 release-gate 陈年红)+
  用户视角发布说明(`75f89d8`,最终波,#68)。

### 状态说明

- **v3.0 开发关账(PHASE 0-21 全部落地)**:发布只差人工打 `v3.0.0` tag 触发发布流水线。
- 3.1(目录物理搬迁)按 V31_MIGRATION_CHECKLIST.md 执行,属下一里程碑。
- 尚未落地(见 V3_MIGRATION_PLAN.md 执行状态段):Home/Composer 余量、平台契约回归、facade 冻结标注、
  双构建 SHA256;本段更新随 3.0.0 版本元数据同步(PHASE 21,plan P15 prep)完成,发布仍未执行。

## 2.0.0 (2026-09-03)

三系统融合版本:Shelly(执行)+ Hermes(记忆)+ DSH(能力),按 V2.0 路线图 PHASE 01→22 落地。

### 新增(core)

- 统一 Runtime:`AgentContext` + `AgentRuntime`(Hermes 钩子内聚),UI 层不再装配引擎;
  `AgentToolRegistry`/`CompositeToolRegistry` 统一注册缝隙。
- Shelly:`WorkspaceManager`(Flutter/Android/Git 项目检测、快照 diff)、
  `ShellExecutor`(四级风险分级,critical 一票否决,fail-closed 审批策略)、
  `GitManager`(porcelain v1)+ `GitSandbox` 全量快照回滚。
- Hermes(无向量库):JSONL 知识账本 + Markdown 投影、CJK 关键词召回、
  经验自动采集、Reflection(精确/近重复归并)、Forgetting(ACTIVE/COOLING/EXPIRED + 频次保护)。
- DSH:声明式插件 Manifest(反向 DNS/semver/权限校验)、生命周期 Registry、
  信任策略(unknown=block/new=ask)、安装器(暂存 `.shelly/plugins/`)、
  Shell 插件命令模板(经宿主 ShellExecutor,仍受 critical 拦截)、Hermes 联动桥。
- 三系统闭环 Demo:`closed_loop_demo_test.dart`(Flutter 登录修复 12 步场景)。
- Provider 预设(OpenAI/DeepSeek/Moonshot/Qwen/OpenRouter/Ollama/LM Studio/自定义)
  + Model Discovery(GET /models,兼容 Ollama 原生形态)。
- AgentProfile:人设/轮次预算/Hermes 采集开关(三预设 + 持久化)。
- 后台 Agent:任务运行记录持久化,进程死亡后经 `TaskRecovery` 扫描恢复。
- 统一 Task Runtime:`TaskState` 扩展 queued/waitingTool/paused/recovering,
  并发上限、排队/暂停/恢复/丢弃、审批等待上报。

### 新增(UI)

- 我的页:Agent 档案选择、Provider 预设 chips、获取模型列表(GET /models)。
- 能力页:DSH 插件安装/生命周期徽章/卸载;插件工具信任列表(封锁/询问/已信任);
  安装的插件进入新任务工具面。
- 对话页:插件工具调用渲染与核心工具一致的工具卡,附「插件」徽标。
- 历史页:被中断任务「可恢复」横幅(从检查点重跑 / 忽略)。
- 任务页:渲染 queued/paused/recovering/waitingTool 四个新任务态。
- 版本标识 → 2.0.0。

### 质量

- `dart analyze` 零问题;`flutter test` 161/161 全绿。

### 打包(全面转云端)

- 打包方式:本地打包环境已移除,release APK 由 GitHub Actions `flutter.yml` 云端构建,
  artifact 名 `shelly-hermes-flutter-release`(release 无 key.properties 时回退 debug 签名)。
- `app-release.apk`(57.3MB,minSdk 24 / targetSdk 36),CI run 33771435104:
  SHA256 `4de542cf7c673b51adf3bdd135f9c94957a25669bfafe4005a992d9d6cc49f62`。
- keystore 与 `key.properties` 不入库。

## 1.0.0 (2026-09-02)

首个 Flutter Android 成品版本。

### 新增(Flutter 主线,`flutter/`)

- Dart 重写 Agent 核心:轮次引擎(token/工具预算、取消)、DiffHunk 审批(expand/collapse)、
  ApprovalBroker(逐 hunk FIFO 队列 + allowAlways)、任务队列(9 态状态机 + 版本化 codec)、
  checkpoint 持久化与恢复(恢复时重建工具卡)、OpenAI 兼容 SSE 流式网关(工具调用映射、超时重试)。
- 策略引擎(自动放行/需确认/禁用)+ JSONL 审计日志;workspace 工具
  (read_file/exists/list_files/search_files/write_file/apply_patch)。
- 对标主流 Agent 的 UI:五 Tab(对话/任务/历史/能力/我的)+ 全屏审批模态;
  三层深灰设计系统(#0A0A0B/#141416/#1E1E21)+ 蓝紫品牌渐变;深浅主题;
  流式打字机与工具卡脉冲动画、Markdown/代码块渲染、骨架屏与空状态。
- Android 平台集成:
  - SAF 工作区目录授权与读写(`dev.shelly/workspace`,持久化 URI 权限);
  - AndroidKeyStore AES/GCM 模型密钥安全存储(`dev.shelly/secure_store`);
  - 前台服务与通知权限引导(`dev.shelly/task_service`,dataSync);
  - 模型 apiKey 经安全存储保存,不再落明文 SharedPreferences。
- CI:`.github/workflows/flutter.yml`(analyze + test + assembleDebug + SHA256 artifact)。

### 打包

- `app-release.apk`(53.5MB,自签名,minSdk 24 / targetSdk 36):
  SHA256 `4a9efdb5535b10fd7dccda7c861769755e5817d92b9f61e70a416977230d4a98`。
- `app-debug.apk`(154MB,调试)。
- 签名脚本 `flutter/android/create_keystore.ps1` 入库;keystore 与 `key.properties` 不入库。

### 兼容性

- Flutter 3.47.2 / Dart 3.13.2;Android 7.0(API 24)及以上。
- 中文路径 Windows 开发机构建需 `subst` 盘符 + `android.overridePathCheck=true`
  (见 PROJECT_STATUS.md)。

### Legacy(保留不演进)

- Kotlin Android app(`app/`)与 TypeScript core(`src/core/`)保持历史状态。
