# Android 与 Windows 适配边界

核心包只使用 `TextStorePort`、`ProcessPort`、`BackgroundTaskPort`、`NotificationPort` 和 `ClockPort`。

## Windows

首版可直接采用 Node 宿主适配器运行核心；桌面 UI 可选 WinUI、Tauri 或 Electron，但不得进入领域核心。文件路径由宿主映射，进程调用始终使用 argv 且不经过 shell。

## Android / Shelly

Android 宿主需要实现相同端口：

- `TextStorePort`：应用工作区文件和原子 rename；
- `ProcessPort`：调用 Shelly 内 Node/Python/Git 运行时；
- `BackgroundTaskPort`：Foreground Service 与 WorkManager；
- `NotificationPort`：进度、暂停、继续、审阅；
- `ClockPort`：系统时间。

Android 生命周期层只能调度核心，不能复制 Agent、Hermes 或策略逻辑。Checkpoint 使用 UTF-8 JSON，可在 Android 与 Windows 间迁移。

## 验证级别

Node 参考宿主用于当前自动化端到端验收。Android 和 Windows 原生 UI/Service 属于下一层宿主工程，必须分别在真实设备及 Windows CI 上做集成验收，不能用 Node 测试冒充实机结果。
