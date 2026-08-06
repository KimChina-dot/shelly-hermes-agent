# Architecture

## 分层

1. **Portable Core**：任务循环、权限策略、插件协议、Hermes、检查点数据结构。
2. **Host Ports**：文件、进程、时钟、密钥、通知、后台调度接口。
3. **Platform Adapters**：Node 开发适配器、Android/Shelly 适配器、Windows 适配器。
4. **Host UI**：Android 原生界面或 Windows 桌面界面。

依赖方向只能从宿主指向核心，核心不得导入 Android、Win32、Electron 或 Node 专属模块。

## 首轮里程碑

- M0：仓库、类型、跨平台端口和测试框架。
- M1：PluginRegistry、能力授权、超时与熔断。
- M2：Hermes 追加、检索、触发计数和预算淘汰。
- M3：文件/进程适配器与 Checkpoint。
- M4：Shelly Android 接入。
- M5：Windows 宿主接入。

## 数据可迁移性

平台适配器只负责 I/O。Checkpoint 和 Hermes 使用带 `schemaVersion` 的 UTF-8 JSON/Markdown；路径在领域层使用逻辑工作区相对路径，宿主负责映射真实路径。
