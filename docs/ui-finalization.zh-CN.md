# UI 定型审计（2026-08-31）

## 目标

Luma Android 界面按“专业、克制、可信赖”的 Agent 工作台定型，采用 Quiet Intelligence 方向：低饱和主色、弱阴影、边框与色阶分层、4/8/12/16/24/32 间距基础、150-250ms 反馈动效。

## 已收口的设计系统

- 颜色、字体、间距、圆角、边框、触控目标使用 `colors.xml`、`dimens.xml` 和 `styles.xml` 统一 Token。
- 浅色与深色主题统一使用 Material 3 `Theme.Material3.DayNight.NoActionBar`，并接入品牌色、表面色、轮廓色和错误色。
- 消息列表、工具卡、任务时间线、审批卡、产物卡、空态、错误卡和状态条复用同一套卡片、芯片、按钮与文本层级。

## 组件覆盖

| 组件 | 当前状态 |
|---|---|
| 对话工作区 | 用户/助手消息、状态消息、流式输出、复制、重新生成已收口 |
| Prompt Composer | 发送、停止、附件、模型选择、角色选择、Plan/Act、键盘发送、运行态锁定已收口 |
| Context Indicator | 输入、附件与上下文用量合并估算，80% 接近上限、95% 超限分级 |
| ToolCallCard | pending/running/finished/failed/cancelled/waiting approval、摘要、开始时间、耗时、展开技术细节、失败建议、重试已覆盖 |
| Task Timeline | 模型、工具名、审批、取消中、结果等真实事件阶段驱动 |
| ApprovalCard | 操作摘要、影响对象、风险等级、参数展开、允许一次/任务内始终允许/拒绝已收口 |
| ArtifactCard | 打开、分享、保存到 Downloads/Luma、复制路径、预览与失败恢复已收口 |

## 状态覆盖

- 空白与首次使用：提供模型设置、选择工作区或聚焦输入的真实入口。
- 正在请求模型 / 正在生成：使用稳定状态语义，不把流片段塞入状态条。
- 正在执行工具 / 等待审批 / 等待新输入：任务状态条与时间线按真实事件变化。
- 生成被停止 / 取消中：提供继续恢复入口和“取消中”阶段。
- 工具失败 / 任务失败：提供失败建议和按错误类型收敛的恢复动作。
- 网络离线：实时横幅，恢复连接后自动收起。
- 上下文过长：区分接近上限和已超限，超限不再提供会重复超长输入的重试路径。
- 任务队列：空态、读取失败、实时广播、取消/重试处理中锁定已收口。
- 历史：状态翻译、部分完成、消息数、检查点、恢复能力、操作状态条已收口。

## 无障碍与响应式

- 主要交互目标统一为 48dp，产物与消息操作提供显式语义。
- 关键状态和错误使用 accessibility live region 或 contentDescription 表达。
- 消息、空态、产物卡和错误卡使用统一最大宽度，避免小屏横向溢出。
- 深色模式、键盘发送、运行态禁用语义和错误恢复路径已完成审查。

## 验证

- `npm run verify`：57/57 项通过，发布门禁通过。
- Android 资源 XML：27/27 项解析通过。
- UI 定型相关改动已推送到 `feat/android-release`，进入 Draft PR #3。

## 当前阻塞

- GitHub Actions 在启动后数秒失败且 `steps` 为空，判断为账户额度/计费阻塞，不是代码编译失败。
- 本机未安装 JDK、Gradle 和 Android SDK，因此无法在本地执行 `:app:assembleDebug`。
- 恢复 GitHub Actions 额度后，应运行 `testDebugUnitTest`、`lintDebug`、`assembleDebug`，下载并人工安装 Debug APK 做真机体验验证。
