# Windows CLI 首个可试用版

该版本把跨平台 Agent 核心接入 OpenAI-compatible Chat Completions API，并提供 Windows/Node 交互命令行。

## 当前能力

- 多轮模型推理与标准 function/tool calling
- 读取工作区文本文件
- 列出工作区目录
- 写入文件（每次必须人工确认）
- 执行非交互命令（每次必须人工确认，不经过 Shell 字符串拼接）
- 路径沙箱、轮次上限、工具调用上限、超时与输出截断

## 环境要求

- Windows 10/11
- Node.js 20 或 22
- 一个兼容 `POST /v1/chat/completions` 和 function calling 的模型服务

## 配置

在仓库根目录执行：

```powershell
Copy-Item .env.example .env
notepad .env
```

填写：

```dotenv
SHELLY_BASE_URL=https://你的服务地址/v1
SHELLY_API_KEY=你的密钥
SHELLY_MODEL=模型名
SHELLY_WORKSPACE=C:\你的项目目录
```

`.env` 已被 Git 忽略，不会被正常提交。不要把真实密钥写进 `.env.example`。

## 启动

在 PowerShell 中：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\hosts\windows\start.ps1
```

也可以手动设置环境变量后运行：

```powershell
npm install
npm run cli
```

输入 `/exit` 退出。

## 安全边界

- Agent 只能访问 `SHELLY_WORKSPACE` 目录树。
- `..` 越界路径和绝对路径会被拒绝。
- 写文件和执行命令默认逐次询问，直接回车等同拒绝。
- 命令通过 `spawn(executable, args, { shell: false })` 执行，降低 Shell 注入风险。
- 本版尚未提供 GUI、补丁预览、Git 自动回滚、会话恢复或 Windows 安装包。
