# Shelly Hermes Agent

面向 Android 的 1.0 Agent 成品(Flutter + Dart),附 Windows CLI 与 TypeScript 核心遗产。

## Flutter 1.0 Android App(当前主线)

- 位置:`flutter/`(org `dev.shelly`,applicationId `dev.shelly.shelly_hermes`)。
- Dart 重写 Agent 核心:流式模型网关、工具策略引擎、逐 hunk 人工审批、checkpoint 恢复、任务队列。
- 平台集成:SAF 工作区读写、AndroidKeyStore 密钥安全存储、前台服务与通知权限。
- 构建:`flutter build apk --release`(需 JDK 17 + Android SDK 36);签名脚本 `flutter/android/create_keystore.ps1`(keystore 不入库)。
- 状态:`version-manifest.json` 1.0.0 · android.status=releasable · 62/62 测试全绿。

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

- 核心(TypeScript legacy):Linux、Windows、macOS;Node.js 20/22。
- Windows:Node CLI 专项 CI 与可校验目录产物。
- Android:**Flutter 1.0 已交付可安装 APK**(debug/release,自签名),CI `flutter.yml` 随每 push 构建并上传 debug 产物。

交付文档：

- [版本清单](version-manifest.json) 与 [升级通道 schema](schemas/update-channel.schema.json)
- [安装与升级](docs/install-upgrade.zh-CN.md)
- [故障排查](docs/troubleshooting.zh-CN.md)
- [隐私说明](docs/privacy.zh-CN.md)
- [签名与密钥安全](docs/security-signing.zh-CN.md)
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

`scripts/package.mjs` 只从锁定清单复制已知文件，按路径排序生成确定性 JSON/SHA256 内容；相同源码、lockfile、Node/TypeScript 版本应产生相同文件内容（目录时间戳不属于内容承诺）。产物写入 `release/shelly-hermes-agent-v<version>/`，生成 `SHA256SUMS` 和 CycloneDX `sbom.cdx.json`。当前流程仅上传未签名 CI 候选产物，不执行真实签名或公开发布。

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
