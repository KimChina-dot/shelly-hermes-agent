# Changelog

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
