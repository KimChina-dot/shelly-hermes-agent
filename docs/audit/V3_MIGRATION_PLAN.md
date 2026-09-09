# v3.0 迁移计划(V3_MIGRATION_PLAN)

> PHASE 0 审计文档 3-3。对齐 v3.0 主计划 Phase 0-15,并按控制器评审结论**适配**:3.0 期**不做目录大挪移**;新模块进新路径(`lib/domain/`、`lib/agent/brain/`、`lib/capability/`);既有模块**以 facade 导出**;物理搬迁整体推迟到 3.1。
> 本计划直接消费同目录三份文档:TEST_COVERAGE_MAP.md(闸门清单)、MIGRATION_RISK.md(R1-R7)、CURRENT_ARCHITECTURE.md / MODULE_MAP.md / DATA_MODEL_MAP.md(结构事实)。

## 0. 适配性总纲(控制器评审决议)

| 决议 | 落地含义 |
| --- | --- |
| 3.0 不动目录 | `lib/core/**`、`lib/state/**`、`lib/features/**` 保持原路径原文件;新增 facade 导出文件(如 `lib/shelly_facade.dart`)聚合再导出,v3 新代码一律 import facade 路径 |
| 新模块进新路径 | Mind/领域模型 → `lib/domain/`;Brain(心智层) → `lib/agent/brain/`;能力端口 → `lib/capability/`;均为**增量目录**,不与现有树交错 |
| 物理搬迁推迟 3.1 | 3.1 用机械替换(facade import → 新路径)+ 648 测试基线兜底 |
| Brain 计入 64K 预算 | Brain 的每次模型调用(context_window.dart:16 deepseek=65536 等)计入同一消耗账本,由 usage_stats(consumedTokens/consumedTokens 汇总)+ AgentCheckpoint.consumedTokens(models.dart:210)记录,禁止旁路网关 |
| Mission/Step/Action 映射 | **Mission = 现有 `task_queue.dart` 的 Task**(TaskState/task_recovery.dart 全链复用);**Step = AgentCore 循环的一轮(round,models.dart:216 AgentCheckpoint.round)**;**Action = 一次工具调用**(CompositeToolRegistry 派发 + PendingToolCall)——不发明并行生命周期 |

## 1. 数据迁移:MigrationManager(v2.3 → v2.4 → v3.0)

对应主计划 §129。实现为新文件 `lib/core/migration/migration_manager.dart`(3.0 期新增目录按"新路径"原则落在 lib/core 下的新子目录,不搬旧文件),五段式:**backup → validate → migrate → verify → rollback**。

- **backup**:首启时把 MIGRATION_RISK.md R1 全部 32 个 `shelly.*` 键原值拷入 `shelly.migration.backup.v3`(单 JSON,含 schemaVersion 与时间戳)。实现参照 features/memory/memory_page.dart:54-57 的备份命名与 core/memory 的导出做法。
- **validate**:逐键 jsonDecode + 形状断言(键清单即验收表);坏键记入 crash 日志(core/crash/crash_log_store.dart)且**不中断启动**。
- **migrate**:仅做"形状转换 + 新键写入",旧键**保留不删**(回滚锚点)。v2.3→v2.4 的中间态(如 ConversationSummary 增加 modelId 字段、settings_store.dart:113)在迁移前已被兼容读消化,migrate 只需处理 v2.4→v3.0 的增量(如 checkpoint version 1→2 双读)。
- **verify**:迁移后回读关键键(shelly.conversations / shelly.memory.facts / shelly.sched.tasks / shelly.checkpoint.*)计数与摘要必须与 backup 记录一致;不一致 → 自动 rollback。
- **rollback**:写新值失败或 verify 失败时,用 backup 覆盖回新键并打 `shelly.migration.state=rolledback`;旧键从未删除,最坏情况 = v3 代码走兼容读。
- 既有先例(必须保留):`restoreApiKey()` 的 legacy apiKey 搬运(settings_store.dart:277-298);memory_backup 导出/导入(core/memory + features/memory/memory_page.dart)。

## 2. Phase 0-15 执行计划

> 每阶段统一闸门:`dart analyze` 0 问题 + `flutter test` ≥648 全绿 + eval 10/10;标注"专项闸门"的另加指定测试。回滚策略 = git revert 该阶段提交序列(每阶段独立 commit 串),数据面风险阶段另跑 MigrationManager rollback。

### PHASE 0 — 架构审计(已完成)
- 入口:基线 648 绿、analyze 干净。
- 出口:docs/audit/ 九文档齐(本任务产出其中 3 份)。
- 受影响文件:仅 docs/audit/*.md。测试闸门:基线复测。回滚:无(纯文档)。

### PHASE 1 — 安全网加固
- 入口:P0 文档评审通过;R6 两处 flake 已甄别记录。
- 出口:补齐 TEST_COVERAGE_MAP.md §3 空洞的最小集——approval_sheet UI、task_service、dsh_provider/hermes_provider 装配测试;bridge_dashboard ticker 注入消雷。
- 受影响文件:test/**(新增),core/mcp/bridge_dashboard.dart(仅注入点)。
- 专项闸门:新增测试全绿;steering/bridge 两文件连续 5 次全量无 flake。回滚:revert 测试 commit(无产品影响)。

### PHASE 2 — lib/domain/ 骨架(纯模型,零行为)
- 入口:P1 出口。
- 出口:`lib/domain/` 定义 Mission/Step/Action 只读模型 + 与现有类型的**映射器**(Mission↔core/task_queue.dart Task;Step=round 序号;Action↔PendingToolCall/core/models.dart),无任何现有文件被改。
- 受影响文件:lib/domain/**(新增)。
- 专项闸门:映射器 round-trip 测试(Task→Mission→Task 恒等)。回滚:删目录。

### PHASE 3 — MigrationManager 落地(只建不跑)
- 入口:P2;R1 键清单冻结。
- 出口:五段式实现 + 单测(fake prefs 驱动 backup/validate/migrate/verify/rollback 五条路径);**生产代码尚不调用**。
- 受影响文件:lib/core/migration/**(新增)、test/core/migration/**(新增)。
- 专项闸门:回滚路径测试(故意断 verify 断言回滚生效)。回滚:删目录。

### PHASE 4 — lib/capability/ 能力端口(接口抽取)
- 入口:P3。
- 出口:`lib/capability/` 定义 ToolCapabilityPort 等接口;core/tools/registry.dart、core/runtime/tool_registry.dart 的**现有实现类以 implements/adapter 满足端口**,调用方零改动(facade 兼容)。
- 受影响文件:lib/capability/**(新增);core/tools、core/runtime 仅追加 adapter 文件。
- 专项闸门:tools_test/runtime_test/eval 10 场景(工具派发顺序不可变:workspace→shell→terminal→notes→memory_search→bridge→knowledge→dsh→mcp)。回滚:revert。

### PHASE 5 — lib/agent/brain/ Brain 接口(脚本化实现)
- 入口:P4。
- 出口:Brain 接口 + ScriptedBrain(复用 eval ScriptedGateway 语义)接入 AgentCore 的**可选**注入点;默认 Brain = 现有直连网关路径,行为逐字节不变(以 recitation/web_search 装饰器链输出快照为准)。
- 受影响文件:lib/agent/brain/**(新增);core/agent_core.dart 增加可选注入参数(默认值保持旧行为)。
- 专项闸门:MIGRATION_RISK.md R2 五组缓存纪律测试 + eval 全绿 + agent_core_test 全绿。回滚:revert 注入参数(默认路径未动)。

### PHASE 6 — Brain 计入 64K 预算
- 入口:P5;64K 口径确认(context_window.dart contextWindowForModel)。
- 出口:Brain 侧每轮调用经统一 token 记账(usage_stats + AgentCheckpoint.consumedTokens),预算超限走现有 limits/压缩路径(core/context/context_compactor.dart),Brain 不得自带旁路 maxTokens。
- 受影响文件:lib/agent/brain/**;state/usage_stats.dart 仅追加 Brain 来源标记字段(可选字段,兼容读)。
- 专项闸门:cache_metrics_test + usage_stats_test + 新增"Brain 调用计入预算"测试。回滚:revert。

### PHASE 7 — Mission API 落到 task_queue
- 入口:P6。
- 出口:domain 映射器上浮 Mission 门面 API(创建/暂停/恢复/取消),内部直接驱动现有 TaskCoordinator/TaskRecoveryRecord;**不复制任务状态机**。
- 受影响文件:lib/domain/**;core/task_queue.dart、core/task_recovery.dart 不改(只读消费)。
- 专项闸门:task_queue_test + task_recovery_test + task_states_test + scheduled_tasks_test 全绿。回滚:revert。

### PHASE 8 — 数据迁移启用(cutover)
- 入口:P7 全绿;发布分支冻结。
- 出口:main.dart 启动串入 MigrationManager.run()(main.dart:9-16 在 crash logging 之后、ProviderScope 之前);v2.3/v2.4 旧档实测升级通过;checkpoint v1/v2 双读生效(R3 缓解 a-c)。
- 受影响文件:lib/main.dart(≤10 行)、lib/core/migration/**。
- 专项闸门:迁移单测 + 手工矩阵(v2.2 档→v2.3 档→v3 档三路升级)+ eval。回滚:MigrationManager 自动 rollback + revert 启动接线。

### PHASE 9 — 审批与策略门面
- 入口:P8。
- 出口:lib/capability/ 增 ApprovalPort;approval_broker/approval_sheet 经端口解耦(R7 缓解第一步);审批表单补齐的 UI 测试转正式闸门。
- 受影响文件:lib/capability/**、features/approval/approval_sheet.dart(import 改 facade)、test/**。
- 专项闸门:approval_broker_test 17 例 + diff_hunk_approval_test 10 例。回滚:revert。

### PHASE 10 — features 消费面收敛
- 入口:P9。
- 出口:R7 表 33 处 import 全部改为 facade 路径(**机械替换,零语义变化**);features 直调 store 方法的热点(model_picker_sheet.dart:99,153,183 等)包一层 domain 查询函数。
- 受影响文件:lib/features/**(import 行)、lib/shelly_facade.dart。
- 专项闸门:widget_test 24 例全绿 + 全量。回滚:revert(纯 import 替换)。

### PHASE 11 — UI 演进(ADD:Home/Composer/Mission Timeline)
- 入口:P10。
- 出口:新界面挂 IndexedStack 新 Tab 或并入现有页;Mission Timeline 读 Mission API(P7),禁直读 task 内部。
- 受影响文件:lib/features/**(新增组件)、lib/design/**。
- 专项闸门:widget_test + 新页面测试。回滚:revert。

### PHASE 12 — 评测扩展
- 入口:P11。
- 出口:test/eval 增 Brain 路径场景(≥5 个新场景,rubric 同 PHASE 46 标准:确定性、无 LLM 评审);负对照延续。
- 受影响文件:test/eval/**。
- 专项闸门:原 10 场景不回归 + 新场景全绿。回滚:revert。

### PHASE 13 — 平台契约回归(Windows/Android)
- 入口:P12。
- 出口:R5 流程脚本化验证——subst X: → assembleDebug/release 冒烟;Android 六通道(dev.shelly/workspace、secure_store、task_service、bg_tasks、hermes_widget 等,见 core/platform/** 文档头)契约测试过。
- 受影响文件:scripts/**(发布脚本)。
- 专项闸门:本机 release 构建 SHA256 产出;platform 相关测试(background_tasks_test、home_widget_bridge_test、workspace_fallback_test)全绿。回滚:revert 脚本。

### PHASE 14 — Facade 冻结 + 3.1 搬迁清单
- 入口:P13。
- 出口:MODULE_MAP.md 每行标注 keep/wrap/move 落定;生成"3.1 物理搬迁清单"(目标路径、机械替换命令、逐文件风险);deprecation 注释先行(@Deprecated 指向 facade)。
- 受影响文件:docs/**、少量注释。
- 专项闸门:全量。回滚:revert 注释。

### PHASE 15 — 发布门禁
- 入口:P14。
- 出口:648+ 全绿、analyze 干净、eval 10/10+新增、迁移矩阵三路通过、本机/CI 双构建 SHA256、CHANGELOG 与 version-manifest 同步;演练一次 MigrationManager rollback 并记录证据。
- 受影响文件:发布元数据。
- 回滚:tag 回退。

## 3. 里程碑与闸门总表

| 阶段 | 性质 | 数据风险 | 关键闸门 |
| --- | --- | --- | --- |
| P0-P1 | 审计+安全网 | 无 | 648 绿;空洞补测 |
| P2-P5 | 增量骨架 | 无(不触旧键) | R2 缓存纪律五测试;eval 10/10 |
| P6-P7 | 行为等价扩展 | 低 | 预算记账测试;task_* 四文件 |
| P8 | **cutover** | **高** | 三路升级矩阵 + 自动 rollback 演练 |
| P9-P12 | 解耦+UI+评测 | 无 | 全量 + widget 24 例 |
| P13-P15 | 发布 | 中 | subst 冒烟;SHA256;rollback 演练 |

## 4. 与 3.1 的交接

3.1 唯一主题 = 物理搬迁:按 P14 清单把 `lib/state/*` → `lib/domain|agent|capability` 对应落位、core 大文件按 MODULE_MAP.md disposition 拆分;每步机械替换 + 全量 648+ 基线;facade 文件保留一个过渡期后删除。3.0 期间任何"顺手搬目录"的冲动都违反本计划的控制器决议,一律拒绝。
