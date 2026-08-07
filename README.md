# Shelly Hermes Agent

面向 Android 与 Windows 的极简编程 Agent 核心。

## 设计约束

- `src/core` 只依赖 TypeScript 标准能力和抽象端口。
- 平台文件系统、进程、后台任务和通知均由适配器注入。
- Android 与 Windows 共享 Agent、Hermes、插件、安全策略和检查点协议。
- 默认最小权限；危险能力必须由宿主显式授权。
- 记忆正文使用可迁移的纯文本格式，不依赖向量数据库。

## Windows CLI（首个可试用版）

已提供 OpenAI-compatible 模型接入、多轮工具调用、工作区文件工具和命令执行审批。详细配置与启动方式见 [`hosts/windows/README.md`](hosts/windows/README.md)。

```powershell
Copy-Item .env.example .env
# 编辑 .env 后
.\hosts\windows\start.ps1
```

## 交付与支持矩阵

- 核心：Linux、Windows、macOS；Node.js 20/22。
- Windows：Node CLI 专项 CI 与可校验目录产物。
- Android：当前仅有 TypeScript bridge/契约测试，**尚不能视为 APK 或实机交付**。

交付文档：

- [CI 与交付审计](docs/delivery-audit.zh-CN.md)
- [Android Host Contract](docs/android-host-contract.zh-CN.md)
- [发行与打包结构](docs/release-structure.zh-CN.md)
- [版本路线与验收门槛](docs/roadmap-and-gates.zh-CN.md)

本地完整验收与打包：

```bash
npm ci
npm run verify
npm run package
```

产物写入 `release/shelly-hermes-agent-v<version>/`，并生成 `SHA256SUMS`。

## 开发

```bash
npm install
npm test
npm run check
npm run build
```

## 目录

```text
src/
  core/       跨平台领域类型和端口
  plugins/    插件注册与能力控制
  hermes/     纯文本知识账本
  adapters/   平台适配器（后续加入 Android、Windows）
examples/     可运行演示
test/         跨平台契约测试
docs/         架构决策
```
