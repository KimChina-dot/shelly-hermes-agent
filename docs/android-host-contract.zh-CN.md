# Android Host Contract（v0.1）

本文是 Android/Shelly 宿主与 TypeScript 核心之间的稳定边界。宿主只实现绑定，不复制 Agent、Hermes、策略或 checkpoint 逻辑。

## 运行时与线程

- Node.js for Android（或等价 JS runtime）加载 `dist/src`；运行时必须支持 ES2022、Promise、AbortSignal。
- 所有绑定均为异步；不得在 UI 线程执行文件、进程、网络或 checkpoint I/O。
- 宿主负责生命周期：前台任务可暂停/恢复，进程重启后从最后一个有效 checkpoint 恢复。

## 必须实现的绑定

`AndroidHostBindings` 对应 `src/adapters/android/index.ts`：

| 能力 | 约定 |
|---|---|
| `readText` / `exists` | 仅允许应用沙盒工作区；不存在返回 `null`/`false` |
| `writeTextAtomic` | UTF-8；同目录临时文件 + 原子 rename；崩溃不能留下半文件 |
| `appendText` | UTF-8 append；父目录不存在时创建 |
| `runProcess` | executable + argv 分离，禁止 shell；超时、输出上限、退出码必须保留 |
| `scheduleTask` / `cancelTask` | taskId 幂等；payload 必须是 JSON；WorkManager/Foreground Service 由宿主选择 |
| `notify` | progress/completion；重复事件可安全重放，敏感内容不得进入通知 |

路径必须是逻辑路径而非任意绝对路径；宿主应拒绝 `..`、NUL、工作区外路径。进程 cwd 同样必须被限制在工作区或明确白名单。

## 权限与安全

默认无网络、无任意文件、无任意命令权限。每个危险工具调用先经过核心 policy/confirm；Android 权限拒绝必须映射为可诊断错误，不得静默成功。

## Checkpoint 与恢复

checkpoint 为 UTF-8 JSON，写入采用临时文件 + rename；至少包含 schemaVersion、taskId、createdAt、conversation、pendingApproval。未知字段须保留，未知 schemaVersion 拒绝恢复并提示迁移。恢复必须幂等，不重复提交已确认副作用。

## Android 验收

必须在真实或 emulator API 34+ 上验证：冷启动恢复、进程被杀恢复、旋转/后台切换、通知进度与完成、权限拒绝、超时、输出截断、工作区逃逸和 checkpoint 原子性。Node 契约测试只能证明映射正确，不能替代设备验收。
