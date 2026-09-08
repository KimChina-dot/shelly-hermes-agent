# Design Brief

> 由 ui_positioning 生成,与 tokens.json/tokens.css 同源;做 UI 前通读,验收时对照。

## 需求
AI Agent 助手 App 深色主题专项打磨:在保持现有浅色一等公民设计不变的前提下,把深色主题打磨到同等精致度——三层深灰层次分明、品牌光晕仅点缀、对比度达 WCAG AA、深色下卡片/浮层/边框语义准确,克制动效与浅色一致

## 视觉方向
- 主风格: **高级感 / Premium** — 内容与留白做主角,低饱和配色 + 细字重大标题,靠层次而不是阴影撑高级感

## 设计参数(与 tokens.css 一致)
- 色板: bg #f5f5f7 / surface #ffffff / text #1d1d1f / accent #1d1d1f / border #e5e5ea
- 圆角: 4px / 8px / 18px
- 字体: -apple-system, BlinkMacSystemFont, 'PingFang SC', 'Helvetica Neue', sans-serif | 基准 17px / 行高 1.6 / 标题字重 600
- 字阶: display 64px · h1 40px · h2 28px · h3 22px
- 间距: 4/8 栅格 · 区块 104px · 容器 1200px(spacious)
- 阴影: none — 层次用底色差(#f5f5f7/#fff)和 1px 边框表达
- 动效: 250ms cubic-bezier(0.16, 1, 0.3, 1)
- 素材: 大尺寸真实摄影,统一色温;禁止卡通插画

## 禁止模式
- ❌ 高饱和渐变
- ❌ 彩色 badge 满天飞
- ❌ 可爱插画
- ❌ 粗黑标题
- ❌ 密集信息堆叠

## 验收标准
- ui_check_design 五项纪律通过:圆角 ≤4 档、字阶 ≤8 档、字体 ≤2 家族、间距落 4/8 栅格、对比度 WCAG AA
- ui_review AI Slop Score ≤ 20(Good 档)
- responsive_audit 无横向溢出;移动端触控目标 ≥ 44px
- token 文件: I:\电脑手机agnet制作\shelly-hermes-release\.design\tokens.json

