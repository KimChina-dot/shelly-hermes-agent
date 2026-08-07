import assert from "node:assert/strict";
import test from "node:test";
import type { AgentTool } from "../src/agent/index.js";
import { PolicyEngine } from "../src/policy/index.js";
import {
  JsonlAuditSink,
  ToolExecutionFramework,
  secureAgentTool,
  truncateResult,
} from "../src/tools/index.js";
import type { TextStorePort } from "../src/core/ports.js";

class MemoryStore implements TextStorePort {
  readonly values = new Map<string, string>();
  async read(path: string) { return this.values.get(path); }
  async writeAtomic(path: string, content: string) { this.values.set(path, content); }
  async append(path: string, content: string) { this.values.set(path, (this.values.get(path) ?? "") + content); }
  async exists(path: string) { return this.values.has(path); }
}

const clock = { now: () => new Date("2026-08-07T00:00:00Z") };

function tool(execute: AgentTool["execute"]): AgentTool {
  return {
    definition: { name: "write", description: "write", inputSchema: { type: "object" } },
    execute,
  };
}

test("unified framework enforces approval and writes redacted audit", async () => {
  const store = new MemoryStore();
  const framework = new ToolExecutionFramework({
    policy: new PolicyEngine({ capabilities: ["fs.write"] }),
    approval: { approve: async () => true },
    audit: new JsonlAuditSink(store),
    clock,
  });
  let ran = false;
  framework.register(secureAgentTool(tool(async () => { ran = true; return { ok: true }; }), {
    capabilities: ["fs.write"], risk: "review", checkpoint: "none",
  }));
  const result = await framework.execute("write", { apiKey: "secret-value" });
  assert.equal(result.ok, true);
  assert.equal(ran, true);
  const audit = store.values.get(".shelly/audit.jsonl") ?? "";
  assert.match(audit, /\[REDACTED\]/);
  assert.doesNotMatch(audit, /secret-value/);
});

test("missing capability denies execution", async () => {
  const framework = new ToolExecutionFramework({
    policy: new PolicyEngine(),
    approval: { approve: async () => true },
    audit: { append: async () => undefined },
    clock,
  });
  framework.register(secureAgentTool(tool(async () => ({ ok: true })), {
    capabilities: ["fs.write"], risk: "review", checkpoint: "none",
  }));
  const result = await framework.execute("write", {});
  assert.equal(result.ok, false);
  assert.match(result.error ?? "", /Missing capabilities/);
});

test("legacy confirmation is not called twice when central approval succeeds", async () => {
  const framework = new ToolExecutionFramework({
    policy: new PolicyEngine({ capabilities: ["fs.write"] }),
    approval: { approve: async () => true },
    audit: { append: async () => undefined },
    clock,
  });
  framework.register(secureAgentTool(tool(async (_input, context) => {
    assert.equal(await context.confirm("legacy"), true);
    return "done";
  }), { capabilities: ["fs.write"], risk: "review", checkpoint: "none" }));
  let fallbacks = 0;
  const result = await framework.execute("write", {}, { confirm: async () => { fallbacks += 1; return false; } });
  assert.equal(result.ok, true);
  assert.equal(fallbacks, 0);
});

test("truncates oversized structured results", () => {
  const result = truncateResult({ value: "x".repeat(1_000) }, 256);
  assert.equal(result.truncated, true);
  assert.equal(result.originalChars !== undefined && result.originalChars > 256, true);
});
