# Android 原生宿主

本目录根部现为可独立构建的 Kotlin/Gradle Android 应用（`minSdk 29`，即 Android 10）。为减少依赖与版本耦合，界面采用原生 XML/View。

## 构建与检查

需 JDK 17、Android SDK 35、Gradle 8.9：

```bash
gradle testDebugUnitTest lintDebug assembleDebug
```

APK 位于 `app/build/outputs/apk/debug/app-debug.apk`。GitHub Actions 在 `feat/android-native` 推送、PR 或手动触发时执行测试、lint 和构建并上传 debug APK。

## 已提供的宿主骨架

- 中文模型配置、目录、任务、审批入口；
- SAF `OpenDocumentTree` 与持久 URI 授权；
- Android Keystore AES-GCM 模型密钥存储接口（仓库不含密钥）；
- 沙盒原子会话存储；
- dataSync 前台服务、低敏通知及会话落盘；
- 审批/Diff 页面；
- `AndroidHostBindings` suspend 桥接契约及逻辑路径防逃逸测试。

生产接入 JS runtime 时应在后台线程实现桥接，并遵守 `docs/android-host-contract.zh-CN.md`；当前工程仅定义稳定契约，不捆绑高风险 runtime。
