import assert from "node:assert/strict";
import test from "node:test";
import { CodingAgent, AgentLimitError } from "../src/agent/index.js";
import type { ChatCompletionRequest, ChatModelPort } from "../src/agent/index.js";

class QueueModel implements ChatModelPort {
  readonly requests: ChatCompletionRequest[] = [];
  constructor(private readonly replies: Array<Awaited<ReturnType<ChatModelPort["complete"]>>>) {}
  async complete(request: ChatCompletionRequest) {
    this.requests.push({ ...request, messages: [...request.messages] });
    const reply = this.replies.shift();
    if (!reply) throw new Error("No queued reply");
    return reply;
  }
}

test("runs a tool call and returns the final answer", async () => {
  const model = new QueueModel([
    {
      message: {
        role: "assistant",
        content: "",
        toolCalls: [{ id: "call-1", name: "echo", arguments: '{"text":"hello"}' }],
      },
      usage: { inputTokens: 10, outputTokens: 2 },
    },
    { message: { role: "assistant", content: "完成" }, usage: { inputTokens: 12, outputTokens: 1 } },
  ]);
  const agent = new CodingAgent(model, [{
    definition: { name: "echo", description: "echo", inputSchema: { type: "object" } },
    async execute(input) { return input; },
  }]);
  const result = await agent.run("开始", { systemPrompt: "system" });
  assert.equal(result.answer, "完成");
  assert.equal(result.toolCalls, 1);
  assert.deepEqual(result.usage, { inputTokens: 22, outputTokens: 3 });
  assert.equal(model.requests[1]?.messages.at(-1)?.role, "tool");
  assert.match(model.requests[1]?.messages.at(-1)?.content ?? "", /hello/);
});

test("turns invalid arguments into a tool error for model recovery", async () => {
  const model = new QueueModel([
    { message: { role: "assistant", content: "", toolCalls: [{ id: "x", name: "echo", arguments: "{" }] } },
    { message: { role: "assistant", content: "参数错误" } },
  ]);
  const agent = new CodingAgent(model, [{
    definition: { name: "echo", description: "echo", inputSchema: {} },
    async execute() { throw new Error("must not run"); },
  }]);
  const result = await agent.run("开始", { systemPrompt: "system" });
  assert.equal(result.answer, "参数错误");
  assert.match(model.requests[1]?.messages.at(-1)?.content ?? "", /valid JSON/);
});

test("enforces the tool-call budget", async () => {
  const model = new QueueModel([{ message: {
    role: "assistant", content: "", toolCalls: [{ id: "x", name: "echo", arguments: "{}" }],
  } }]);
  const agent = new CodingAgent(model, [{
    definition: { name: "echo", description: "echo", inputSchema: {} },
    async execute() { return {}; },
  }]);
  await assert.rejects(agent.run("开始", { systemPrompt: "system", maxToolCalls: 0 }), AgentLimitError);
});
