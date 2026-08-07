# CI 与交付审计（基线）

## 当前发现

- 已有 `.github/workflows/windows.yml`，覆盖 npm ci、测试、类型检查、build、demo 和 smoke，但只有单 job，未上传产物，也没有 Linux/macOS 或 Node 版本矩阵。
- `package.json` 仅有 build/check/test/demo/cli，没有统一 verify、package、产物清单或发布入口；项目仍是 `private: true` 的 0.1.0 MVP。
- Android 适配器已有最小绑定与契约测试，仍需 host contract、生命周期/权限/真实设备验收。
- README 已是中文，但缺少支持矩阵、发行说明、验收门槛和 Android 接入说明。

## 交付骨架

- 核心 CI：`.github/workflows/core.yml`，Linux/Windows/macOS × Node 20/22，运行 verify/package 并上传 release artifact。
- Windows CI：保留 `windows.yml` 作为 host 专项；建议改为调用同一 verify 脚本并上传 Windows 包。
- Android：`docs/android-host-contract.zh-CN.md` 作为宿主实现与设备验收基准。
- 发行：`docs/release-structure.zh-CN.md` 定义核心包、Windows 包、Android 独立宿主和哈希规则。
- 路线：`docs/roadmap-and-gates.zh-CN.md` 定义 0.1 → 1.0 与阻断条件。

## 验收证据

CI 日志、测试报告、release 目录、SHA256SUMS、Android emulator/设备日志和人工审批记录都应作为可追溯证据保存；Node 测试不得冒充 Android/Windows 原生验收。
