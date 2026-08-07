# 版本路线与验收门槛

## 版本路线

### 0.1.0 MVP（当前）

完成跨平台核心端口、Node 参考宿主、Windows CLI、OpenAI-compatible 模型、审批式工具、Hermes 文本记忆、checkpoint，以及单元/契约测试。定位为开发预览，不承诺 Android 实机可用。

### 0.2.0 Host-ready

补齐可消费的 package exports、稳定错误码与 checkpoint schema、跨平台 CI、Windows 安装/升级包、Android host contract 和 emulator smoke；API 变更需有迁移说明。

### 0.3.0 RC

Android API 34+ 实机完成后台/恢复/通知/权限验收；Windows x64 CLI 可重复安装；安全审计无 P0/P1；发布包可离线校验并有 SBOM/许可证清单。

### 1.0.0

核心 API、端口和 checkpoint schema 承诺 semver 兼容；Android 与 Windows 各有受支持版本矩阵、回滚策略、崩溃诊断和发布签名。

## 合并门槛（每个 PR）

- `npm ci` 可复现；`npm run check`、`npm test`、`npm run build` 全通过。
- Linux/Windows/macOS × Node 20/22 核心矩阵通过；Windows host smoke 通过。
- 新增端口或适配器必须有正向、错误、超时、权限和边界测试。
- 不引入 shell 拼接、工作区逃逸、明文 secret；安全相关改动需人工 review。
- 公共 API/配置/错误行为变化必须更新中文文档与变更记录。

## 发布门槛

所有合并门槛 + 真实 Windows runner 通过 + Android API 34+ emulator smoke；RC/稳定版还需真实设备恢复测试、干净环境安装、升级/回滚演练、产物哈希与审计记录。任何 P0/P1 缺陷、未签名产物、可泄露 secret 或不可恢复 checkpoint 均阻止发布。
