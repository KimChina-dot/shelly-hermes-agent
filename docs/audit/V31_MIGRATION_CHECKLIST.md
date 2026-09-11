# V3.1 物理搬迁清单(PHASE 19 产出 · V3 计划 P14)

> 冻结基线:main `ad2bdb7`(PHASE 18)+ 本提交(PHASE 19)。冻结时点闸门:`dart analyze` 0 问题 + `flutter test` 829 全绿。
> 3.1 唯一主题 = 物理搬迁(V3_MIGRATION_PLAN §4):本清单是唯一权威;清单外的任何"顺手搬目录/顺手重构"一律拒绝并回控制器重新规划。
> 处置依据:`docs/audit/MODULE_MAP.md` 各表「3.1 处置」列(keep 62 + wrap 31 + move 6,legacy 表 99 行)。

## 0. 执行纪律(每一步都必须遵守)

对齐 V3_MIGRATION_PLAN §2 阶段闸门与 §4 交接约定:

1. **单步单闸门**:每完成一个搬迁项(大项 M1 按子步 M1a/M1b/M1c 拆开,每个子步独立成步)→ `dart analyze`(0 问题)→ `flutter test`(829 全绿;测试文件只允许随被测文件同步 `git mv`,**用例数不得增减**)→ 独立 commit。任一红 → `git revert` 该步,禁止现场"顺手修"业务代码。
2. **锚点规则**:features 层 100% 经 `lib/shelly_facade.dart` 消费 core/state(PHASE 16,14 个 features 文件;唯二例外:`features/approval/approval_sheet.dart` 的 `state/chat_session` 直连【PHASE 12 端口策略,M1c 改写】与 `design/components/tool_card.dart` 的 ToolEntry 直连【M1a 改写】)。因此搬迁一个模块 = 改 facade 里**一行 export** + 修复 lib 内部与 test 的直连 import。禁止新增任何绕过 facade 的 features 直连 import。
3. **替换到零残留**:每步收尾必须验证 `grep -rn "<旧路径片段>" lib test --include="*.dart"` 为空(旧路径片段见各项命令最后一条)。facade 里被替换掉的旧 export 行同样计入残留检查。
4. **行为冻结**:搬迁不改任何逻辑/命名/签名/测试断言。若发现"不改逻辑就过不了闸门",说明该项风险评级失效 → 中止该步并回控制器;唯一例外是 M1b 的私有类公开化(见该条风险列,允许且仅允许 `_` 前缀去除)。
5. **执行顺序**:**M2 → M3 → M4 → M5 → M6 → M1**(风险递增;M1 依赖 M2 先落位,chat_session 三拆压轴)。M1 内部严格 M1a → M1b → M1c。
6. **环境**:Git Bash;`export PATH="/i/flutter/bin:$PATH"`;命令均在 `flutter/` 目录执行;`sed -i` 失败时用 python 行替换等效执行(命令语义不变)。

## 1. 搬迁项总表

| 编号 | 文件(现路径) | 目标路径 | 风险 | 直连 import 面(冻结时点实测) |
| --- | --- | --- | --- | --- |
| M2 | `lib/state/dsh_provider.dart` | `lib/capability/dsh/dsh_provider.dart` | 低 | 4 处:facade + chat_session + capability/dsh/dynamic_skill_host + 1 测试 |
| M3 | `lib/state/hermes_provider.dart` | `lib/application/hermes_provider.dart` | 低 | 3 处:facade + 2 测试 |
| M4 | `lib/state/memory_maintenance.dart` | `lib/application/memory_maintenance.dart` | 低 | 2 处:facade + 1 测试 |
| M5 | `lib/core/runtime/agent_runtime.dart` | `lib/agent/runtime/agent_runtime.dart` | 中低 | 3 处:chat_session + 2 测试(不经 facade) |
| M6 | `lib/core/tools/memory_search_tool.dart` | `lib/capability/tools/memory_search_tool.dart` + ConversationSummary 下沉 `lib/domain/chat/conversation_summary.dart` | 中 | 2 处 import + 全库唯一 core→state 反向边(DEPENDENCY_MAP §3.1) |
| M1 | `lib/state/chat_session.dart`(1899 行) | 三拆:`lib/domain/chat/chat_entry.dart` + `lib/agent/session_runtime.dart` + `lib/application/chat_session_controller.dart` | **高** | 26 处:facade + approval_sheet + tool_card + 23 测试文件 |

## 2. 逐项明细

> 三列口径:**目标路径** = git mv 落位;**机械替换命令** = 以 facade import / 直连 import 为锚点的可执行命令(冻结时点实测的替换面,执行时先跑 grep 复核);**逐文件风险** = 测试基线依赖 / 循环 import 风险 / 字符串与反射引用。行号为冻结基线 ad2bdb7+,执行时以符号名为准。

### M2 — `state/dsh_provider.dart` → `lib/capability/dsh/dsh_provider.dart`(21 行,最低风险,首战练手)

| 列 | 内容 |
| --- | --- |
| 目标路径 | `lib/capability/dsh/dsh_provider.dart`(与 dynamic_skill_host.dart 同目录;能力层 provider 装配归位,同时消除 capability→state 反向边) |
| 机械替换命令 | `git mv lib/state/dsh_provider.dart lib/capability/dsh/dsh_provider.dart`<br>`sed -i "s\|export 'state/dsh_provider.dart';\|export 'capability/dsh/dsh_provider.dart';\|" lib/shelly_facade.dart`<br>`sed -i "s\|import 'dsh_provider.dart';\|import '../capability/dsh/dsh_provider.dart';\|" lib/state/chat_session.dart`<br>`sed -i "s\|import '../../state/dsh_provider.dart';\|import 'dsh_provider.dart';\|" lib/capability/dsh/dynamic_skill_host.dart`<br>`sed -i "s\|package:shelly_hermes/state/dsh_provider.dart\|package:shelly_hermes/capability/dsh/dsh_provider.dart\|" test/state/dsh_provider_test.dart`<br>`git mv test/state/dsh_provider_test.dart test/capability/dsh/dsh_provider_test.dart`(可选,目录对应)<br>`dart analyze && flutter test`<br>`grep -rn "state/dsh_provider" lib test --include="*.dart"`(必须为空) |
| 逐文件风险 | 测试基线:`test/state/dsh_provider_test.dart` 装配断言(dshRegistry/dshTrust/dshTools 三 provider),搬迁零语义变化应直接绿。循环 import:无——dsh_provider 只依赖 core/dsh(单向);dynamic_skill_host 的 `../../state/...` 直连变为同目录 import 后,capability→state 边清零。字符串/反射:无(grep 全库仅 import 行命中;dsh_provider 不含 `shelly.*` 持久化键)。 |

### M3 — `state/hermes_provider.dart` → `lib/application/hermes_provider.dart`

| 列 | 内容 |
| --- | --- |
| 目标路径 | `lib/application/hermes_provider.dart`(跨 core/hermes × state 的账本快照编排,与 mission_coordinator.dart 同层) |
| 机械替换命令 | `git mv lib/state/hermes_provider.dart lib/application/hermes_provider.dart`<br>`sed -i "s\|import 'chat_session.dart';\|import '../state/chat_session.dart';\|; s\|import 'settings_store.dart';\|import '../state/settings_store.dart';\|" lib/application/hermes_provider.dart`(自身 import 修正;`../core/...` 深度不变)<br>`sed -i "s\|export 'state/hermes_provider.dart';\|export 'application/hermes_provider.dart';\|" lib/shelly_facade.dart`<br>`sed -i "s\|package:shelly_hermes/state/hermes_provider.dart\|package:shelly_hermes/application/hermes_provider.dart\|" test/state/hermes_provider_test.dart test/core/memory_settings_test.dart`<br>`dart analyze && flutter test`<br>`grep -rn "state/hermes_provider" lib test --include="*.dart"`(必须为空) |
| 逐文件风险 | 测试基线:`hermes_provider_test.dart`(快照/整理)+ `memory_settings_test.dart`(借道引用)两文件直连,均 package: 风格,子串替换即净。循环 import:低——搬入 application/ 后新增边 `application/hermes_provider → state/chat_session、state/settings_store`,方向为 application→state(合法,application 层编排 state);chat_session 不回引 hermes_provider,facade 是唯一正向出口。字符串/反射:无。注意:hermesLedgerProvider 被 features/memory 经 facade watch,export 行改写即收敛,features 零改动。 |

### M4 — `state/memory_maintenance.dart` → `lib/application/memory_maintenance.dart`

| 列 | 内容 |
| --- | --- |
| 目标路径 | `lib/application/memory_maintenance.dart`(维护服务编排:consolidation + memory_store + 日节流) |
| 机械替换命令 | `git mv lib/state/memory_maintenance.dart lib/application/memory_maintenance.dart`(自身 import 全为 `../core/memory/...`,state→application 同深,零修正)<br>`sed -i "s\|export 'state/memory_maintenance.dart';\|export 'application/memory_maintenance.dart';\|" lib/shelly_facade.dart`<br>`sed -i "s\|package:shelly_hermes/state/memory_maintenance.dart\|package:shelly_hermes/application/memory_maintenance.dart\|" test/state/memory_maintenance_test.dart`<br>`git mv test/state/memory_maintenance_test.dart test/application/memory_maintenance_test.dart`(可选)<br>`dart analyze && flutter test`<br>`grep -rn "state/memory_maintenance" lib test --include="*.dart"`(必须为空) |
| 逐文件风险 | 测试基线:`memory_maintenance_test.dart` 单文件直连。循环 import:无(仅依赖 core/memory,home_shell 经 facade 触发)。字符串/反射:无。home_shell 的 `_runMemoryMaintenance` 副作用经 facade 消费,export 改写即收敛。 |

### M5 — `core/runtime/agent_runtime.dart` → `lib/agent/runtime/agent_runtime.dart`

| 列 | 内容 |
| --- | --- |
| 目标路径 | `lib/agent/runtime/agent_runtime.dart`(引擎组装职责归 agent 层,与 brain/ 同层;旧 v3 处置"Brain 组装缝"随迁) |
| 机械替换命令 | `git mv lib/core/runtime/agent_runtime.dart lib/agent/runtime/agent_runtime.dart`<br>`sed -i "s\|import '../agent_core.dart';\|import '../../core/agent_core.dart';\|; s\|import '../approval_broker.dart';\|import '../../core/approval_broker.dart';\|; s\|import '../models.dart';\|import '../../core/models.dart';\|; s\|import '../tools/registry.dart';\|import '../../core/tools/registry.dart';\|; s\|import 'agent_context.dart';\|import '../../core/runtime/agent_context.dart';\|" lib/agent/runtime/agent_runtime.dart`(自身 5 条 import 全量改写;agent_context 原地不动)<br>`sed -i "s\|import '../core/runtime/agent_runtime.dart';\|import '../agent/runtime/agent_runtime.dart';\|" lib/state/chat_session.dart`(M1 前提下;若 M1 已先行则目标文件已是 `lib/application/chat_session_controller.dart`)<br>`sed -i "s\|package:shelly_hermes/core/runtime/agent_runtime.dart\|package:shelly_hermes/agent/runtime/agent_runtime.dart\|" test/core/runtime_test.dart test/core/closed_loop_demo_test.dart`<br>`dart analyze && flutter test`<br>`grep -rn "core/runtime/agent_runtime" lib test --include="*.dart"`(必须为空) |
| 逐文件风险 | 测试基线:`runtime_test.dart`(AgentRuntime 装配)+ `closed_loop_demo_test.dart`(闭环演示)直连 package: 路径。循环 import:无——新位置 `agent/runtime → core/{agent_core,approval_broker,models,tools/registry,runtime/agent_context}` 全为向下依赖;agent_context 留在 core/runtime 不随迁(它是参数包接口,被 hermes_memory 实现,搬走会扩大替换面)。字符串/反射:无。注意:该模块**不在 facade 导出集**(features 不直接消费),所以没有 export 行可改——这是与 M2-M4 的关键差异,全部替换面就是 chat_session + 2 测试。 |

### M6 — `core/tools/memory_search_tool.dart` → `lib/capability/tools/memory_search_tool.dart`(附 ConversationSummary 下沉)

| 列 | 内容 |
| --- | --- |
| 目标路径 | `lib/capability/tools/memory_search_tool.dart`(自诊断工具归能力层);同时把 `ConversationSummary` 类从 `lib/state/settings_store.dart` 下沉到新文件 `lib/domain/chat/conversation_summary.dart`,settings_store 原地 `export '../domain/chat/conversation_summary.dart';` 兼容再导出(零行为) |
| 机械替换命令 | 第一步(符号下沉,先做、独立闸门):从 `lib/state/settings_store.dart` 剪出 `ConversationSummary` 类定义(含 fromJson 工厂)到新文件 `lib/domain/chat/conversation_summary.dart`(头部仅需 `dart:convert`);在 settings_store.dart 加 `export '../domain/chat/conversation_summary.dart';`;`dart analyze && flutter test`。第二步(文件搬迁):`git mv lib/core/tools/memory_search_tool.dart lib/capability/tools/memory_search_tool.dart`<br>`sed -i "s\|import '../crash/crash_log_store.dart';\|import '../../core/crash/crash_log_store.dart';\|; s\|import '../memory/memory_store.dart';\|import '../../core/memory/memory_store.dart';\|; s\|import '../models.dart';\|import '../../core/models.dart';\|; s\|import '../runtime/tool_registry.dart';\|import '../../core/runtime/tool_registry.dart';\|; s\|import '../tools/registry.dart';\|import '../../core/tools/registry.dart';\|; s\|import '../tools/workspace.dart' show decodeArguments;\|import '../../core/tools/workspace.dart' show decodeArguments;\|; s\|import '../../state/settings_store.dart' show ConversationSummary;\|import '../../domain/chat/conversation_summary.dart' show ConversationSummary;\|" lib/capability/tools/memory_search_tool.dart`<br>`sed -i "s\|import '../core/tools/memory_search_tool.dart';\|import '../capability/tools/memory_search_tool.dart';\|" lib/state/chat_session.dart`<br>`sed -i "s\|package:shelly_hermes/core/tools/memory_search_tool.dart\|package:shelly_hermes/capability/tools/memory_search_tool.dart\|" test/core/tools/memory_search_tool_test.dart`<br>`dart analyze && flutter test`<br>`grep -rn "core/tools/memory_search_tool\|state/settings_store.dart' show ConversationSummary" lib test --include="*.dart"`(必须为空) |
| 逐文件风险 | 测试基线:`memory_search_tool_test.dart` 直连;ConversationSummary 下沉涉及 `settings_store_test.dart`/`chat_session_test.dart` 等 settings 消费面(经再导出保持绿,若红说明下沉不完整——禁止改断言,回退补 export)。循环 import:下沉后 `capability/tools → domain/chat`(合法向下)+ `state/settings_store → domain/chat`(合法);core→state 的全库唯一反向边就此清零(DEPENDENCY_MAP §3.1 关账)。字符串/反射:`ConversationSummary` 的 JSON 键(`shelly.conversations` 条目形状)是 R1 迁移键面——**类移动不触碰任何 JSON 键名/字段名**,MigrationManager(PHASE 10/18)的 30 条 key spec 不受影响;执行后必须抽测 `test/core/migration/` 全目录。 |

### M1 — `state/chat_session.dart` 三拆(1899 行,压轴,分三个子步)

冻结基线符号地图(行号为 ad2bdb7+ 时点,执行时以符号为准):`ChatEntry` 族 61-114(含 `ToolRunStatus`@92)、`SessionPhase`@115、`ChatSessionState`@117、`ChatSessionController`@179、`_ApprovalRouter`@852、`_NotesStateApprovalPolicy`@1059、`_TaskRunner`@1114、`_SessionObserver`@1565、`_MissionBridge`@1643、`_StoreCheckpoints`@1697、`DemoModelGateway`@1713。

| 列 | 内容 |
| --- | --- |
| 目标路径 | M1a:`lib/domain/chat/chat_entry.dart` ← `ChatEntry` 密封族 + `ToolRunStatus`(纯模型,零 import);M1b:`lib/agent/session_runtime.dart` ← `_NotesStateApprovalPolicy` + `_TaskRunner` + `_StoreCheckpoints` + `DemoModelGateway`(引擎装配工厂);M1c:余量(`ChatSessionState`、`SessionPhase`、`ChatSessionController`、`_ApprovalRouter`、`_SessionObserver`、`_MissionBridge`、全部 provider)`git mv` → `lib/application/chat_session_controller.dart`。 |
| 机械替换命令 | **M1a**(先做,含 design 反向边解除):新建 `lib/domain/chat/chat_entry.dart` 贴入 61-114 行(仅需 `package:flutter/foundation.dart` 若 immutable 注解存在,否则零 import);chat_session.dart 原位置删除并加 `export '../domain/chat/chat_entry.dart';`(桥接,23 个测试与 facade 全部免改);`sed -i "s\|import '../../state/chat_session.dart';\|import '../../domain/chat/chat_entry.dart';\|" lib/design/components/tool_card.dart`(design→state 反向边 §3.2 清零);`dart analyze && flutter test`(此步 829 必须原绿,零替换面波动)。<br>**M1b**:把 `_NotesStateApprovalPolicy`/`_TaskRunner`/`_StoreCheckpoints`/`DemoModelGateway` 四块剪出到 `lib/agent/session_runtime.dart`,私有类**仅去 `_` 前缀公开**(TaskRunner/StoreCheckpoints/DemoModelGateway/NotesStateApprovalPolicy,除前缀外一字不改);chat_session.dart 改 `import '../agent/session_runtime.dart';` 并同步引用点改名(纯机械 `sed "s\|_TaskRunner\|TaskRunner\|g"` 级);`dart analyze && flutter test`。**稳妥路径**:若公开化步子太大,允许先以 `part 'session_runtime.dart';` + `part of` 桥接过闸(私有名全保留、零引用改写),下一个子步再公开化——二选一,不许混合。<br>**M1c**(须在 M2 之后):`git mv lib/state/chat_session.dart lib/application/chat_session_controller.dart`;修正自身 import:三条 state 同胞(`'dsh_provider.dart'` 已在 M2 变 `'../capability/dsh/dsh_provider.dart'`;`'settings_store.dart'`→`'../state/settings_store.dart'`;`'usage_stats.dart'`→`'../state/usage_stats.dart'`)、其余 `../core/...`/`../platform/...`/`../agent/...`/`../capability/...`/`../domain/...`/`../skills/...`/`../application/mission_coordinator.dart` 深度不变零改动;`sed -i "s\|export 'state/chat_session.dart';\|export 'application/chat_session_controller.dart';\nexport 'domain/chat/chat_entry.dart';\|" lib/shelly_facade.dart`(M1a 的桥接 export 升为 facade 正式导出,chat_session 内部的 chat_entry export 行删除);`sed -i "s\|import '../../state/chat_session.dart';\|import '../../application/chat_session_controller.dart';\|" lib/features/approval/approval_sheet.dart`;测试面批量:`grep -rln "package:shelly_hermes/state/chat_session.dart" test \| xargs sed -i "s\|package:shelly_hermes/state/chat_session.dart\|package:shelly_hermes/application/chat_session_controller.dart\|g"`(23 个文件,含 `show` 子句变体,子串替换全覆盖;仅消费 ChatEntry 族的测试文件可改指 `package:shelly_hermes/domain/chat/chat_entry.dart`);`git mv test/state/chat_session_test.dart test/application/chat_session_controller_test.dart`(其余 22 个测试文件名不动,避免替换面膨胀);`dart analyze && flutter test`;<br>`grep -rn "state/chat_session" lib test --include="*.dart"`(必须为空) |
| 逐文件风险 | 测试基线(最高):23 个测试文件直连(实测 grep;chat_session_test / regenerate / session_management / steering / context_meter / aux_model / brain_integration / conversation_export / mission_coordinator / hermes_provider / usage_stats / widget_test / eval×2 / memory×2 / capability / features×2 / platform×1 等)——M1a 的 export 桥与 M1c 的子串批量替换是唯一防线,**每子步全量 829 兜底,禁改任何断言**。循环 import:M1c 后新增 `application/chat_session_controller → capability/dsh(M2)、agent/session_runtime(M1b)、state/{settings,usage}` 全为向下/同层合法边;反向唯一残留是 features 内部 `history_page → shell/home_shell(tabIndexProvider)` 与 `profile_page → app(themeModeProvider)`(§3.4,属 provider 收口议题,不在本清单)。字符串/反射:`chatGatewayOverrideProvider` 是 `@visibleForTesting` 测试缝(chat_session 声明,8 个测试文件引用,随 M1c 改写);**工具表组装顺序(workspace→shell→terminal→memory_search→knowledge→notes→dsh→mcp→bridge)是安全属性**,M1b 剪出 `_TaskRunner` 时必须整块搬运、逐行等价,`tools_test.dart`/`eval/` 场景即哨兵;`DemoModelGateway` 仅 chat_session 内部使用(实测零外部引用),随 M1b 走。|

## 3. 不搬迁项说明(防止 3.1 范围蔓延)

- `state/settings_store.dart`(586 行,wrap):R1 全部 32 个 `shelly.*` 键与 MigrationManager(PHASE 10/18)锚定此文件;整体搬迁零收益、纯风险。3.1 只做 M6 的 ConversationSummary 符号下沉。
- `core/gateway/openai_gateway.dart`(keep):预算钩子缝已由 `lib/agent/brain/brain_gateway.dart`(PHASE 8 共享 64K 账本)落地;网关本体与 9 个测试文件原路径保留。
- `core/tools/**`、`core/shell/**`、`core/mcp/**`、`core/dsh/**` 其余文件(keep):工具派发顺序是安全属性(runtime/tool_registry 先声明者赢),整目录平移到 capability/ 属"顺手搬目录",拒绝;capability 层已经端口方式消费它们(PHASE 4-7)。
- features 页面大文件(chat_page 2363 行等,keep):UI 拆分属 3.0 P11 余量(Home/Composer),不是 3.1 目录搬迁主题。
- `lib/shelly_facade.dart`(keep):搬迁全部完成后保留一个过渡期,确认零直连后随 3.2 删除(V3_MIGRATION_PLAN §4)。

## 4. 验收(3.1 完成定义)

1. 六项(或含 M1 三子步共八步)全部落地,每步独立 commit + 全量 829 绿记录在案;
2. `grep -rn "state/chat_session\|state/dsh_provider\|state/hermes_provider\|state/memory_maintenance\|core/runtime/agent_runtime\|core/tools/memory_search_tool" lib test --include="*.dart"` 为空;
3. `lib/state/` 目录保留(12 文件中仅 5 个随 M1-M4 迁出:chat_session、dsh_provider、hermes_provider、memory_maintenance + M6 涉及的 ConversationSummary 符号;settings_store 等 7 文件按 MODULE_MAP「3.1 处置」wrap 原路径保留),禁止目录级清空动作;
4. DEPENDENCY_MAP §3.1(core→state)与 §3.2(design→state)两条反向边清零,复测依赖图归档;
5. facade 每行 export 均指向新路径,且 `dart analyze` 0 问题。
