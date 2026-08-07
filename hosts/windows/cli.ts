import { createInterface } from "node:readline/promises";
import { stdin, stdout } from "node:process";
import { CodingAgent } from "../../src/agent/index.js";
import { NodeProcessAdapter, NodeTextStore } from "../../src/adapters/node/index.js";
import { OpenAICompatibleChatModel } from "../../src/models/index.js";
import { PolicyEngine } from "../../src/policy/index.js";
import {
  CallbackApproval,
  JsonlAuditSink,
  ToolExecutionFramework,
  createWorkspaceTools,
  secureWorkspaceTools,
} from "../../src/tools/index.js";
import { loadHostConfig, redactConfig } from "./config.js";
import { probeModels } from "./health.js";
import { JsonLogger } from "./logger.js";
import { SessionStore } from "./sessions.js";
import { close, createLocalServer, listen } from "./server.js";

const config = await loadHostConfig({ args: process.argv.slice(2) });
const logger = new JsonLogger(config.dataDir, config.logLevel);
const sessions = new SessionStore(config.dataDir);
let session = await sessions.create();
const probe = await probeModels(config);
if (!config.model) config.model = probe.selectedModel;
if (!config.model) throw new Error(probe.error ?? "无法确定模型");

const terminal = createInterface({ input: stdin, output: stdout });
const workspaceStore = new NodeTextStore(config.workspace);
const rawTools = createWorkspaceTools({
  root: config.workspace,
  store: workspaceStore,
  process: new NodeProcessAdapter(config.workspace),
});
const execution = new ToolExecutionFramework({
  policy: new PolicyEngine({
    capabilities: ["fs.read", "fs.write", "process.safe", "process.dangerous", "git.read", "git.write"],
  }),
  approval: new CallbackApproval(async (request) => {
    const answer = (await terminal.question(`\n确认：${request.message} [y/N] `)).trim().toLowerCase();
    return answer === "y" || answer === "yes";
  }),
  audit: new JsonlAuditSink(workspaceStore),
  clock: { now: () => new Date() },
  defaultMaxResultChars: 100_000,
});
execution.registerAll(secureWorkspaceTools(rawTools));

const model = new OpenAICompatibleChatModel({
  baseUrl: config.baseUrl,
  apiKey: config.apiKey,
  model: config.model,
  timeoutMs: config.timeoutMs,
});
const agent = new CodingAgent(model, execution.asAgentTools());
const server = createLocalServer(config);
await listen(server, config);
let active: AbortController | undefined;
let stopping = false;

console.log(`Shelly CLI | ${config.model} | ${config.workspace}`);
console.log(`会话 ${session.id}；/help 查看命令；Ctrl+C 取消当前任务，再按一次退出。`);
await logger.log("info", "host_started", {
  model: config.model,
  workspace: config.workspace,
  port: config.port,
});

const shutdown = async () => {
  if (stopping) return;
  stopping = true;
  active?.abort();
  terminal.close();
  await close(server);
  await logger.log("info", "host_stopped");
};
process.on("SIGINT", () => {
  if (active) {
    active.abort();
    stdout.write("\n[已请求取消]\n");
  } else {
    void shutdown();
  }
});
process.on("SIGTERM", () => void shutdown());

try {
  while (!stopping) {
    let prompt: string;
    try {
      prompt = (await terminal.question("\n你> ")).trim();
    } catch {
      break;
    }
    if (!prompt) continue;
    if (prompt.startsWith("/")) {
      if (await command(prompt)) break;
      continue;
    }

    active = new AbortController();
    try {
      const result = await agent.run(prompt, {
        systemPrompt: [
          "你是 Shelly，一名谨慎实用的中文编程 Agent。",
          `工作区：${config.workspace}。`,
          "先读后改，不编造执行结果。所有工具统一经过能力策略、审批和审计管道。",
        ].join("\n"),
        history: session.messages,
        signal: active.signal,
        maxTurns: config.maxTurns,
        maxToolCalls: config.maxToolCalls,
        // Unified execution framework owns approval. Legacy fallback remains deny-by-default.
        confirm: async () => false,
        onEvent(event) {
          if (event.type === "tool_start") stdout.write(`\n[工具] ${event.name}\n`);
        },
      });
      session.messages = result.messages.slice(1);
      await sessions.save(session);
      console.log(`\nShelly> ${result.answer}`);
      await logger.log("info", "run_finished", {
        sessionId: session.id,
        turns: result.turns,
        toolCalls: result.toolCalls,
      });
    } catch (error) {
      const cancelled = active.signal.aborted;
      console.error(cancelled ? "\n任务已取消" : `\n任务失败：${message(error)}`);
      await logger.log(cancelled ? "info" : "error", cancelled ? "run_cancelled" : "run_failed", {
        sessionId: session.id,
        error: message(error),
      });
    } finally {
      active = undefined;
    }
  }
} finally {
  await shutdown();
}

async function command(line: string): Promise<boolean> {
  const [cmd, arg] = line.split(/\s+/, 2);
  switch (cmd) {
    case "/help":
      console.log("/new  /sessions  /resume <id>  /health  /config  /clear  /cancel  /exit");
      return false;
    case "/new":
      session = await sessions.create();
      console.log(`新会话 ${session.id}`);
      return false;
    case "/sessions":
      console.table(await sessions.list());
      return false;
    case "/resume":
      if (!arg) console.log("用法：/resume <id>");
      else {
        session = await sessions.load(arg);
        console.log(`已恢复 ${session.id}`);
      }
      return false;
    case "/clear":
      session.messages = [];
      await sessions.save(session);
      console.log("当前会话已清空");
      return false;
    case "/health":
      console.log(await probeModels(config));
      return false;
    case "/config":
      console.log(redactConfig(config));
      return false;
    case "/cancel":
      active?.abort();
      console.log(active ? "已请求取消" : "当前没有运行中的任务");
      return false;
    case "/exit":
    case "/quit":
      return true;
    default:
      console.log(`未知命令 ${cmd}；输入 /help`);
      return false;
  }
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
