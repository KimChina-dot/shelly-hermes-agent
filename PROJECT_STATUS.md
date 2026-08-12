# Luma 项目开发状态

> 原名：Shelly Hermes
> 当前分支：`feat/android-release`
> 内部引擎：Hermes Core
> 更新日期：2026-08-12

## 本轮完成

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
