# Windows host / CLI 审计与运行说明

## 审计结论

旧版 `cli.ts` 仅直接读取四个环境变量；文档要求 `.env`，但 Node/脚本并未可靠加载它。每个输入都是独立 `agent.run`，没有跨任务历史、持久会话、模型发现、健康端点或结构化日志；Ctrl+C 会直接结束 readline，无法区分取消任务与退出；启动时也不验证模型服务。

本实现保持零运行时依赖，拆为可测试组件：

- `config.ts`：优先级 `defaults < shelly.config.json < .env < process env < CLI`，校验、路径归一化、密钥脱敏。
- `sessions.ts`：`~/.shelly/sessions/*.json` 原子写入，会话创建/列出/恢复。
- `health.ts`：带超时的 `GET /models` 探测，可自动采用首个模型。
- `server.ts`：仅监听 `127.0.0.1:43821`；提供带会话 Cookie 与 CSRF 防护的桌面 API，`/healthz` 为进程存活，`/readyz` 为模型就绪。
- `desktop.ts` / `web/`：零大型运行时依赖的本地 Web 桌面入口与静态 UI。
- `logger.ts`：`~/.shelly/logs/shelly.jsonl` JSONL，敏感字段脱敏。
- `cli.ts`：持久上下文、确认、取消和优雅关闭。

## 配置

复制 `.env.example`，或创建 `shelly.config.json`：

```json
{
  "baseUrl": "http://127.0.0.1:11434/v1",
  "apiKey": "local",
  "model": "qwen2.5-coder:7b",
  "workspace": "C:\\src\\my-project",
  "dataDir": "C:\\Users\\me\\.shelly",
  "timeoutMs": 120000,
  "maxTurns": 12,
  "maxToolCalls": 24,
  "host": "127.0.0.1",
  "port": 43821,
  "logLevel": "info"
}
```

所有字段也支持 `SHELLY_*` 环境变量以及如 `--model m --workspace C:\\src --port 43821` 参数。不要把服务绑定到 `0.0.0.0`：健康服务没有认证，设计用途仅为本机守护/托盘集成。

## 使用

```powershell
npm install
npm run check
npm test
npm run cli -- --workspace C:\src\project
```

命令：`/help`、`/new`、`/sessions`、`/resume <id>`、`/clear`、`/health`、`/config`、`/cancel`、`/exit`。运行任务时按 Ctrl+C 请求取消；空闲时 Ctrl+C 优雅退出。探针：`Invoke-RestMethod http://127.0.0.1:43821/healthz`。

会话文件含用户/模型内容，不含 API key，但仍可能含源码片段；请按敏感数据保护 `dataDir`。JSONL 日志只记录元数据和错误，不记录完整 prompt。
