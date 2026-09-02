# Changelog

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
