# Luma — 项目开发状态

> 原名：Shelly Hermes
> 分支：`feat/android-release`
> 引擎：`Hermes Core`

---

## 一、已完成的功能

### 跨平台核心（core 模块）

- [x] `AgentCore` 任务循环：模型调用→工具执行→审批→恢复
- [x] `ApprovalGateway` + `ApprovalBroker` 审批挂起/恢复机制
- [x] `DiffApproval` 模型：DiffHunk、HunkDecision、DiffApprovalState
- [x] 检查点持久化、取消信号、轮次与 Token 预算限制

### Android 宿主（app 模块）

- [x] SAF 工作区目录选择与持久化权限
- [x] `SafWorkspaceFileExecutor`：read/create/overwrite/append/exists
- [x] `AndroidApprovalGateway` + `ApprovalBridge` 单例
- [x] `TaskForegroundService` 作为协调器宿主
- [x] 前台通知、任务状态同步
- [x] 模型配置加密存储（Android Keystore AES-GCM）
- [x] 模型设置与 API Key 保存
- [x] 主页与审批页 UI 骨架（基于 XML/View 架构）
- [x] 毛玻璃卡片组件、统一颜色与样式系统

### 全量测试

- [x] TypeScript 核心测试 50/50 通过
- [x] Kotlin 核心测试（ApprovalBrokerTest、DiffApprovalTest、AgentCoreTest）
- [x] Android XML 资源解析验证
- [x] 路径安全与逻辑路径验证

---

## 二、尚未完成

### 高优先级

- [ ] 主界面改为对话流布局 + 底部固定输入 + 底部导航
- [ ] "能力"页面（Skills / MCP / 模型 / 工具与权限）
- [ ] UI 品牌名从 Hermes 调整为 Luma（用户可见部分）
- [ ] 深色模式与毛玻璃性能降级
- [ ] 逐 hunk Diff 审批交互 + 文件级切换 + 拒绝理由
- [ ] 正确设置 Android 编译环境并构建 Debug APK

### 中优先级

- [ ] 任务历史与筛选
- [ ] 模型配置页
- [ ] 工作区管理
- [ ] 定时任务与提醒
- [ ] 应用内通知与任务状态同步

### 低优先级/远期

- [ ] 动效：加载、状态转场、审批完成
- [ ] 横屏/平板适配
- [ ] 无障碍与大字体
- [ ] 真机验收
- [ ] Release 签名、CI 构建、APK 发布
- [ ] Windows 端适配

---

## 三、本地环境

| 项目 | 状态 |
|------|------|
| JDK 17 | ✅ 可用 |
| Gradle | ❌ 无（需 Android SDK） |
| Android SDK | ❌ 无 |
| kotlinc | ❌ 无 |
| Node.js | ✅ 可用 |
| npm | ✅ 可用 |
| Python 3 | ✅ 可用 |
| 浏览器截图 | ❌ 无 headless Chromium |

Kotlin 与 Android 构建依赖 CI（GitHub Actions）验证。

---

## 四、Git 历史

```
feat/android-release...origin/main [ahead 9]

88bfef4 feat(android): execute approved file tools through SAF workspace
6b5f1fd feat(android): implement diff approval loop with broker gateway
6555d05 fix(android): harden SAF workspace access
1e23914 feat(android): add secure model settings dialog
e08d1ca feat(android): connect agent runtime and model gateway
a9476ec feat(android): build production agent workspace UI
e2c204a feat(android): add portable agent core
```

远程仓库: `https://github.com/KimChina-dot/shelly-hermes-agent.git`

---

## 五、项目名称建议

正式命名为 **Luma**，内部引擎保留 **Hermes Core**。

底部导航结构：
- 对话 / 任务 / 能力 / 我的

Skills 与 MCP 统一归入"能力"页。

---

*最后更新: 2026-08-11*