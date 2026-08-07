import assert from "node:assert/strict";
import test from "node:test";
import { OpenAICompatibleChatModel } from "../src/models/index.js";

test("maps messages, tools and usage to OpenAI-compatible format", async () => {
  let body: any;
  const model = new OpenAICompatibleChatModel({
    baseUrl: "https://example.test/v1/",
    apiKey: "secret",
    model: "test-model",
    fetch: async (input, init) => {
      assert.equal(input, "https://example.test/v1/chat/completions");
      body = JSON.parse(String(init?.body));
      assert.equal(new Headers(init?.headers).get("authorization"), "Bearer secret");
      return new Response(JSON.stringify({
        choices: [{ message: { content: null, tool_calls: [{
          id: "c1", type: "function", function: { name: "read_file", arguments: '{"path":"a"}' },
        }] } }],
        usage: { prompt_tokens: 4, completion_tokens: 2 },
      }), { status: 200, headers: { "content-type": "application/json" } });
    },
  });
  const result = await model.complete({
    messages: [{ role: "user", content: "hi" }],
    tools: [{ name: "read_file", description: "read", inputSchema: { type: "object" } }],
  });
  assert.equal(body.model, "test-model");
  assert.equal(body.tools[0].function.name, "read_file");
  assert.equal(result.message.toolCalls?.[0]?.name, "read_file");
  assert.deepEqual(result.usage, { inputTokens: 4, outputTokens: 2 });
});

test("reports an HTTP error without exposing request credentials", async () => {
  const model = new OpenAICompatibleChatModel({
    baseUrl: "https://example.test/v1",
    apiKey: "top-secret-key",
    model: "m",
    fetch: async () => new Response("bad gateway", { status: 502 }),
  });
  await assert.rejects(
    model.complete({ messages: [{ role: "user", content: "hi" }] }),
    (error: Error) => error.message.includes("502") && !error.message.includes("top-secret-key"),
  );
});
