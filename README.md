# Shelly Hermes Agent

运行在 Android 上的本地 AI Agent 工作台(Flutter + Dart):Shelly 执行、Hermes 知识、DSH 插件三系统融合,外加分层个人记忆;模型调用、工具执行、审批与记忆全部以本机为中心。

**为什么是本地 Agent**:对话与工作区文件留在设备上;每一次写入文件、打补丁、执行命令等关键动作都先经用户审批;长期记忆以纯文本存放在本机,不依赖向量数据库与云端同步。模型接入走用户自己配置的 OpenAI 兼容端点(含 Ollama / LM Studio 等本机推理)。

## 功能一览

**Agent 核心**
- 多轮工具调用循环(`AgentCore`),预算护栏:16 轮 / 64k token / 32 次工具调用(`AgentLimits`)。
- 关键动作逐项审批(`ApprovalBroker`);`apply_patch` 拆成 diff hunk 逐块批准(`DiffHunkApproval`),已批准项可持久化放行。
- Shell 四级风险分级(low/medium/high/critical):low 放行、medium/high 询问、critical 一票否决(`shell/shell_executor.dart`)。
- 上下文压缩(`context/context_compactor.dart`),CJK 感知的 token 估算,压缩后可从 checkpoint 恢复。
- 任务运行时(`task_queue.dart`):排队 / 等待审批 / 暂停 / 恢复;进程被杀后由 `task_recovery.dart` 从 checkpoint 扫描恢复。

**工具面**
- 工作区文件操作:read_file / write_file / apply_patch / list_files / exists / search_files(`tools/workspace.dart`)。
- 终端搜索:`fast_find`(fd,缺失回退 find)、`smart_grep`(rg,缺失回退 grep),返回结构化 JSON(`tools/terminal_tools.dart`)。
- `plan` / `note` 工具:当前计划与进度每轮回注系统提示词(`tools/notes_tool.dart`)。
- `search_memory`:Agent 主动检索自己的长期记忆(`tools/memory_search_tool.dart`)。

**模型网关**
- OpenAI 兼容 SSE 流式网关(`gateway/openai_gateway.dart`),按模型配置 temperature / top_p,统计 prompt cached tokens。
- Provider 预设:OpenAI / DeepSeek / Moonshot / Qwen / OpenRouter / Ollama / LM Studio / 自定义(`gateway/providers.dart`),`GET /models` 模型发现。
- 按模型启用厂商联网搜索开关(`gateway/web_search.dart`)。

**记忆(两层,纯文本)**
- 分层个人记忆(`memory/memory_store.dart`):core 恒驻系统提示词、recall 按预算自动注入、archival 仅经 `search_memory` 取用(Letta 式三层);`MemoryExtractor` 从对话中提取事实,`memory/consolidation.dart` 做睡眠期整理(合并/降级/淘汰/摘要)。
- Hermes 知识账本(`hermes/`):JSONL 账本 + Markdown 投影、反思归并、遗忘策略,服务项目级知识。

**扩展与外部能力**
- MCP:HTTP 客户端 + 工具注册表;供应链防护 `mcp/mcp_guard.dart` 对工具目录做 SHA-256 指纹,目录漂移强制重新审批(防 tool poisoning / rug pull)。
- 桌面桥接:Windows/macOS/Linux 侧 `dart run tool/mcp_bridge.dart` 托管 stdio MCP 服务器,经 LAN HTTP 暴露给手机(`mcp/bridge_server.dart` / `bridge_client.dart` / `bridge_dashboard.dart`)。
- DSH 插件系统(`dsh/`):manifest 校验、生命周期注册表、信任策略(unknown=block / new=ask)。

**平台集成**
- SAF 工作区(用户授权目录树)、安全存储(`secure_box.dart`)、桌面小部件桥、WorkManager 后台唤醒(`platform/background_tasks.dart`,原生侧 `BackgroundTaskWorker.kt`)。
- TTS 朗读、崩溃记录(`crash/crash_log_store.dart`)、LAN 伴侣服务(`lan/`)、Git 快照与回滚(`git/`)。

**界面**:五 Tab 导航 —— 对话 / 任务 / 历史 / 能力 / 我的(`features/shell/home_shell.dart`),对应 `lib/features/` 下 chat / tasks / history / capabilities / memory / profile 等页面。

## 架构速览

```text
flutter/lib/
  core/       引擎与平台无关逻辑(agent 循环、审批、网关、工具、记忆、MCP、任务)
  features/   页面层(chat / tasks / history / capabilities / memory / profile / approval)
  state/      Riverpod 状态装配(chat_session、任务调度、设置、用量统计)
  platform/   平台通道适配(SAF 工作区、进程执行、语音、安全存储)
  design/     主题与组件(design tokens、亮/暗主题)
```

依赖方向:features → state → core;core 不导入 Flutter 页面层。模块逐个说明见 [docs/architecture.md](docs/architecture.md)。

## 构建与运行

前置:Flutter stable(仓库按 3.47.x 开发)、Android SDK(minSdk 24)、JDK 17。

```bash
cd flutter
flutter pub get
flutter run                # 连接设备或启动模拟器
flutter build apk          # 构建 release APK(build/app/outputs/flutter-apk/)
```

打包完全走 git 云端:GitHub Actions 在每次 push/PR 构建 debug + release APK 并上传 artifact;签名密钥不入库,`android/key.properties` 缺失时 release 构建回退 debug 签名。

## 测试

```bash
cd flutter
flutter test               # 全量单元/组件测试(620+ 用例)
flutter test test/eval     # 10 场景轨迹级 eval 基线(确定性,无网络无 LLM 裁判)
```

eval 基线驱动真实 `AgentCore` + 工具注册表 + 策略引擎,校验「产出与轨迹」而非固定路径;任何提交都要求 10 个场景全绿。CI(`.github/workflows/flutter.yml`)在 push/PR 上执行 analyze + test + 双 APK 构建。

## 桌面 MCP 桥接

在电脑上把 stdio MCP 服务器暴露给手机(同一 LAN):

```bash
cd flutter
dart run tool/mcp_bridge.dart --port 8766 --token <你的令牌> --config servers.json
```

`servers.json` 是 stdio 服务器定义数组(id / name / command / args / env)。随后在手机 App「能力」页 →「桌面 MCP 桥接」填入 `http://<电脑IP>:8766` 与令牌;加 `--headless` 可跳过交互式面板(脚本/CI 场景)。

## 截图

<!-- TODO: 补充对话页 / 任务页 / 能力页 / 记忆页截图 -->

## 发布

版本通过 git tag 触发(`v*` → 构建 + 发布 GitHub Release),当前版本 3.0.0。历史版本与 APK / SHA256SUMS 下载见
[Releases](https://github.com/KimChina-dot/shelly-hermes-agent/releases)。

## 相关文档

- [架构说明](docs/architecture.md)
- [隐私说明](docs/privacy.zh-CN.md)
- [签名与密钥安全](docs/security-signing.zh-CN.md)
- [故障排查](docs/troubleshooting.zh-CN.md)
- [Windows 桌面(遗留)](docs/windows-desktop.zh-CN.md)

> 仓库仍保留早期 TypeScript 核心(`src/`)与 Windows CLI(`hosts/`)作为遗产代码,当前主线是 `flutter/`。
