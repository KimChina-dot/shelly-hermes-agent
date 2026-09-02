# Shelly Hermes 1.0 项目状态

> 当前分支：`feat/android-release`
> 内部引擎：Hermes Core(TypeScript 遗产)+ Dart Agent Core(Flutter 1.0 主线)
> 更新日期：2026-09-02

## 1.0 交付状态(Flutter Android 成品,2026-09-02)

- **Flutter 1.0 Android App 已完成开发、集成与打包**,仓库位于 `flutter/`(org `dev.shelly`,applicationId `dev.shelly.shelly_hermes`)。旧 Kotlin app 与 TypeScript core 保留为 legacy,不再演进。
- **技术栈**:Flutter 3.47.2 / Dart 3.13.2;Dart 重写 Agent 核心(轮次引擎、DiffHunk 审批、ApprovalBroker、checkpoint、任务队列、OpenAI 兼容 SSE 网关、策略引擎 + 审计 JSONL)。
- **UI**:五 Tab 信息架构(对话/任务/历史/能力/我的)+ 逐 hunk 审批模态;三层深灰设计系统 + 蓝紫品牌渐变;流式打字机、工具卡脉冲动画、Markdown/代码块渲染;每页经前端 MCP(Chrome 真机交互/截图/控制台清零)验收。
- **质量基线**:`dart analyze` 零问题;`flutter test` **62/62 全绿**(含 checkpoint 恢复重建工具卡、审批队列、SSE 解析、patch 语义等)。
- **Android 平台集成**:SAF 目录授权与读写(`dev.shelly/workspace`)、AndroidKeyStore AES/GCM 密钥安全存储(`dev.shelly/secure_store`,apiKey 不再落明文 prefs)、前台服务 + 通知权限引导(`dev.shelly/task_service`,foregroundServiceType=dataSync)。
- **打包产物**:
  - `flutter/build/app/outputs/flutter-apk/app-release.apk`(53.5MB,自签名,SHA256 `4a9efdb5535b10fd7dccda7c861769755e5817d92b9f61e70a416977230d4a98`,minSdk 24 / targetSdk 36)
  - `flutter/build/app/outputs/flutter-apk/app-debug.apk`(154MB,调试用途)
  - 签名:自签名 keystore(`flutter/android/create_keystore.ps1` 入库,**keystore 与 key.properties 不入库**)
- **构建环境备注**(中文路径机器):gradle wrapper 走腾讯镜像;`android.overridePathCheck=true` + `kotlin.incremental=false` 解决 AGP/Kotlin 对非 ASCII 路径的兼容;release AOT 需经 `subst X:` 盘符路径构建(脚本化见下)。
- **CI**:新增 `.github/workflows/flutter.yml`(pub get → analyze → test → assembleDebug → SHA256 artifact),与 legacy android.yml 并存。
- **版本清单**:`version-manifest.json` → 1.0.0(android.status=releasable),`package.json` 同步 1.0.0,release gate PASS。

### Windows 本机构建 release APK 流程

```powershell
subst X: "I:\电脑手机agnet制作\shelly-hermes-release"   # AOT 快照器不兼容非 ASCII 路径
cd X:\flutter
flutter build apk --release                              # 需 JAVA_HOME=JDK17, ANDROID_HOME=I:\android-sdk
subst X: /D
```

## 历史基线(legacy Kotlin / TS 线)

- 恢复归档中的 Git 元数据，项目目录现为可用的 `feat/android-release` 工作树；原无效 worktree 指针保留为 `.git.worktree-pointer`。
- 修复 Android 主界面和审批页中损坏的 UTF-8 文本、未闭合 XML 属性及无效资源引用。
- 用户可见品牌改为 **Luma**，内部包名和 Hermes Core 暂不迁移。
- 移除对未声明 AppCompat 依赖的使用，模型设置对话框改用平台 `AlertDialog`。
- 根构建脚本补充 Kotlin JVM 插件版本，供 `core` 模块解析。
- 主界面发送按钮现在会校验任务、模型配置和 SAF 工作区，并将真实任务文本交给前台服务。
- 接通任务停止、运行状态广播、进度/错误/完成消息和审批等待状态。
- 新增 `OpenAiAgentModelGateway`，完成 OpenAI-compatible 消息、工具调用及 token usage 映射。
- 新增 `SafWorkspaceToolExecutor`，以白名单方式映射 `read_file`、`exists`、`create_file`、`overwrite_file`、`append_file`。
- 前台服务不再启动硬编码演示任务；空 Intent 不会因 `START_STICKY` 重复产生副作用。
- 新增只读“能力”页，展示模型、SAF 工作区、工具白名单和人工审批安全边界。

## 已验证

- `npm run verify`：通过。
- TypeScript 测试：50/50 通过。
- TypeScript 类型检查、构建、发布门禁：通过。
- Android 资源 XML UTF-8 解析：5/5 通过。
- Android 源码乱码和未配对普通字符串静态扫描：通过。
- 能力页资源与 Manifest 引用静态检查：通过。
- Android CI 工作流改为显式执行 `core` JVM 测试、App 单元测试、Lint 和 Debug APK 构建。
- 首次 GitHub Android 构建已定位并修复资源链接问题：补齐 `TextAppearance.Luma` 基样式。
- 第二次 GitHub 构建暴露并修复 `ApprovalBrokerTest` 的协程调度竞态，测试现在显式推进测试调度器。
- 工具调用链新增生命周期事件、耗时统计和失败状态，Android 前台任务会实时显示当前阶段。
- `read_file` 与 `exists` 默认免审批，写入类工具继续强制人工审批，减少无副作用工具的等待卡顿。
- 新增任务历史页，保存最近 100 个任务，兼容旧版记录并支持清空。
- GitHub Lint 已定位并修复历史页 Activity 重复注册问题；APK 打包阶段本身已通过。

## 当前限制

- 当前机器未安装 JDK、Android SDK、Gradle/Gradle Wrapper，尚不能本地执行 `testDebugUnitTest`、`lintDebug` 或 `assembleDebug`。
- 因此本轮 Android 改动已做静态验证，但仍需 CI 或具备 Android SDK 35 的环境完成真实编译和 APK 验证。
- 核心 `AgentMessage` 尚不能原生持久化 assistant tool-call 消息；Android gateway 通过任务内映射补全协议历史，进程重启后的工具调用恢复仍需专项设计。
- 当前仅支持单活动任务；任务历史、恢复和多任务调度尚未实现。

## 下一阶段优先级

1. 在 CI 执行 `testDebugUnitTest lintDebug assembleDebug`，修复真实 Android 编译问题并保存 Debug APK。
2. 为 OpenAI 请求/响应 codec 和 SAF 工具路由补充可在 JVM 执行的测试层。
3. 将审批页升级为逐 hunk Diff、文件切换和拒绝理由。
4. 完成“对话 / 任务 / 能力 / 我的”底部导航及能力页。
5. 增加深色主题、任务历史、进程恢复和通知权限引导。
