import { resolve } from "node:path";
import { createInterface } from "node:readline/promises";
import { stdin, stdout } from "node:process";
import { CodingAgent } from "../../src/agent/index.js";
import { NodeProcessAdapter, NodeTextStore } from "../../src/adapters/node/index.js";
import { OpenAICompatibleChatModel } from "../../src/models/index.js";
import { createWorkspaceTools } from "../../src/tools/index.js";

const workspace = resolve(process.env.SHELLY_WORKSPACE ?? process.cwd());
const baseUrl = required("SHELLY_BASE_URL");
const apiKey = required("SHELLY_API_KEY");
const modelName = required("SHELLY_MODEL");
const model = new OpenAICompatibleChatModel({ baseUrl, apiKey, model: modelName });
const tools = createWorkspaceTools({
  root: workspace,
  store: new NodeTextStore(workspace),
  process: new NodeProcessAdapter(workspace),
});
const agent = new CodingAgent(model, tools);
const terminal = createInterface({ input: stdin, output: stdout });

console.log(`Shelly Hermes Agent CLI\n工作区：${workspace}\n模型：${modelName}`);
console.log("输入任务并回车；输入 /exit 退出。写文件和执行命令会逐次确认。\n");

try {
  while (true) {
    const prompt = (await terminal.question("你> ")).trim();
    if (!prompt) continue;
    if (["/exit", "/quit"].includes(prompt)) break;
    try {
      const result = await agent.run(prompt, {
        systemPrompt: [
          "你是 Shelly，一名谨慎、实用的中文编程 Agent。",
          `你的工作区是 ${workspace}。`,
          "先阅读相关文件再修改；只使用提供的工具；不要编造执行结果。",
          "写文件和执行命令必须等待宿主确认。任务完成后简洁总结改动与验证结果。",
        ].join("\n"),
        confirm: async (question) => {
          const answer = (await terminal.question(`\n确认：${question} [y/N] `)).trim().toLowerCase();
          return answer === "y" || answer === "yes";
        },
        onEvent(event) {
          if (event.type === "tool_start") stdout.write(`\n[工具] ${event.name}\n`);
        },
      });
      console.log(`\nShelly> ${result.answer}\n`);
    } catch (error) {
      console.error(`\n任务失败：${error instanceof Error ? error.message : String(error)}\n`);
    }
  }
} finally {
  terminal.close();
}

function required(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`缺少环境变量 ${name}，请参考 .env.example`);
  return value;
}
