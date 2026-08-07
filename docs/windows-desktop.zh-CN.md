# Windows 桌面产品骨架

Shelly Desktop 使用 **Node.js 内置 HTTP + 原生 HTML/CSS/JS**，没有 Electron、WebView2 SDK 或前端框架等大型运行时依赖。宿主在本机启动后打开系统默认浏览器，因此可与既有 CLI 并存。

## 功能

- 聊天、创建/恢复会话；会话仍保存于 `dataDir/sessions`。
- 脱敏配置和健康状态；可通过宿主回调接入配置持久化。
- 审批队列、统一 Diff 展示及批准/拒绝操作。
- 任务日志视图；API 状态结构可由真正 Agent 执行层填充。
- 静态资源随发行包离线提供，不使用 CDN。

## 安全边界

1. `config.ts`、`listen()` 和 `createLocalServer()` 三层均拒绝非 `127.0.0.1` 地址；不支持局域网暴露。
2. 打开 `/` 时生成并设置进程内随机 `HttpOnly; SameSite=Strict` 会话 Cookie，所有 `/api/*` 均验证。
3. 每个写请求还必须携带页面内随机 `X-Shelly-CSRF` token；使用恒定时间比较。
4. CSP 禁止第三方脚本/连接/框架，提供 `nosniff`、`DENY`、`no-referrer`；API 不返回 API key。
5. 请求体限制 1 MB，消息限制 20,000 字符，静态路径阻止目录穿越。

这套 token 防护用于阻止其他网页驱动 localhost API；它不防御能读取当前用户浏览器/进程内存的本机恶意软件。

## 启动

```powershell
npm ci
npm run desktop -- --workspace C:\src\project
# 不自动打开浏览器
npm run desktop -- --no-open
# 原 CLI 保留
npm run cli -- --workspace C:\src\project
```

默认地址为 `http://127.0.0.1:43821/`。`/healthz` 可匿名用于本机存活探测；业务 API 必须认证。桌面骨架的默认聊天回包只说明尚未注入运行器，产品集成时通过 `createLocalServer(config, { onChat, onConfig, state })` 接入 Agent、审批器和日志源。

## 验证与发行

```powershell
npm run check
npm test
npm run build
npm run package
```

发行目录包含 `hosts/windows/web` 静态资源、TypeScript 编译产物、PowerShell 启动器、中文文档和 `SHA256SUMS`。
