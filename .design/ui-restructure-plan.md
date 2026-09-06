# PHASE 44 — UI 重构规划(浅色为主 · 主流精致 · 克制动效)

> 方法:frontend MCP(ui_analyze_request → ui_positioning → agent-ui/motion-design 指南)
> 定调结论存于 `.design/tokens.json` + `.design/project.json`,验收时 `ui_check_design` 会对账。

## 一、定位结论(MCP 产出)

- **风格**:Premium 高级感——内容与留白做主角,低饱和配色,细字重标题,靠层次不靠阴影堆砌。
- **浅色为一等公民**:浅色是默认主题;深色保留但降级为次要(代码里仍双主题完整,验收只按浅色走查)。
- **红线**(MCP 反模式清单):高饱和渐变、彩色 badge 满天飞、粗黑标题、密集堆叠、每个元素都动一点。

## 二、Token 变更(T1)

`lib/design/tokens.dart`:

| Token | 旧(深色一等) | 新(浅色一等) |
|---|---|---|
| lightBackground | #FAFAFB | #F5F5F7(苹果系冷灰底) |
| lightCard | #FFFFFF | #FFFFFF |
| lightFloating | #F1F1F4 | #ECECF1(输入框/嵌套面板底) |
| lightBorder | #E6E6EC | #E5E5EA |
| lightTextPrimary | #17171C | #1D1D1F |
| lightTextSecondary | #5C5C66 | #6E6E73 |
| lightTextTertiary | #9A9AA5 | #AEAEB2 |
| 品牌渐变 | 蓝→紫 #3B82F6→#8B5CF6 | **降级使用**:仅头像/加载态;主按钮改纯色墨黑 #1D1D1F(Premium 色板 accent) |
| danger | #F87171(浅色刺眼) | #FF3B30(浅色)/ 深色保留 |

新增 `AppMotion` 扩展(动效三律:只动 transform/opacity、入场 ease-out、密度高处少动):
- `fast 150ms`(微交互:按钮/开关)
- `normal 250ms`(进出场/浮层),`emphasized = Cubic(0.16, 1, 0.3, 1)`(高级感位移曲线)
- `slow 350ms`(页面级)
- `staggerInterval = 40ms`(列表级联,最多前 8 项)

## 三、布局与组件重构(T2/T3)

导航壳(home_shell):浅色底 + 顶部安全区;NavigationBar 指示器改为胶囊淡灰底 + 选中墨黑图标(消 surfaceTint)。

页面改造点(全部走语义色,深色自动继承):
1. **对话页**:背景 #F5F5F7;助手消息全宽无气泡;用户消息白底卡(投影柔和 8% 透明墨色、r18);工具卡白底细边;输入栏白底胶囊浮起 + 阴影;打字机光标已有,补"思考中"三点脉冲。
2. **历史页**:搜索胶囊化;列表卡白底 r18、置顶标记弱化为灰阶图钉;级联入场 stagger 40ms(前 8 项)。
3. **任务页**:状态三态对齐 agent-ui 规范——等待(灰点脉冲)/执行中(旋转+步骤文案)/完成(✓);定时任务卡白底 r18。
4. **能力页**:分区标题细字重 + 灰阶;插件卡/开关行白底 r18;移除彩色 pill 改灰阶+墨黑选中。
5. **我的页**:各分区卡白底 r18、区块间距 32;开关统一 Material3 浅色;用量统计数字用大字号细字重。
6. **审批页**(视觉重量最高):浅色下风险色只保留描边+图标,大面积白底;diff 区浅色语法高亮。
7. **共享组件**(buttons/empty_state/skeleton/tool_card/risk_chip/gradient_avatar/gradient_button):GradientButton → 主按钮墨黑底白字 + 150ms 按压缩放 0.97;骨架屏改浅灰渐变;risk_chip 灰阶化。

## 四、动效清单(克制)

| 场景 | 动效 | 参数 |
|---|---|---|
| Tab 切换 | 内容淡入 | 150ms ease-out,位移 8px |
| 列表入场 | 级联淡入+上移 | 250ms emphasized,级联 40ms×前8 |
| 主按钮 | 按压缩放 | 150ms,scale 0.97 |
| 工具卡执行中 | 脉冲边框/旋转 | 线性,仅运行态 |
| 等待态 | 三点脉冲 | 1s 循环,opacity 0.4→1 |
| 浮层(审批/选择器) | 底部滑入+背景淡入 | 250ms emphasized |
| 完成态 | ✓ 描边缩放入场 | 200ms ease-out |

不做的:循环弹跳图标、装饰漂浮、页面级视差、每元素都动。

## 五、实施顺序与验收

1. **T1** tokens/theme(+`AppMotion` 新曲线、墨黑 accent)
2. **T2** 共享组件 7 个 + home_shell
3. **T3** 六页(对话→历史→任务→能力→我的→审批)
4. **T4** Flutter Web(`flutter run -d chrome`,dev-only)+ MCP:`ui_check_design` 对账 token 纪律(圆角三档 8/18/999,字阶纪律,文本色 ≤3 种,对比度 WCAG)→ `take_screenshot` 逐页留档 → `responsive_audit` 375/768/1440
5. **T5** 全量 flutter test 回归(浅色断言不破坏现有测试;必要时更新硬编码断言)→ PR → main

## 六、明确不做

- 不换信息架构(五 Tab 保持);不新增页面;不引入第三方字体文件;不打包 APK。
- 深色主题只保持"不坏",不做深色专项打磨。
