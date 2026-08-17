import assert from "node:assert/strict";
import test from "node:test";
import type { TextStorePort } from "../src/core/ports.js";
import { SessionEventLog, SessionEventLogError } from "../src/session/index.js";

class MemoryStore implements TextStorePort {
  readonly values = new Map<string, string>();
  async read(path: string) { return this.values.get(path); }
  async writeAtomic(path: string, content: string) { this.values.set(path, content); }
  async append(path: string, content: string) { this.values.set(path, (this.values.get(path) ?? "") + content); }
  async exists(path: string) { return this.values.has(path); }
}

test("appends ordered facts and derives model-visible messages", async () => {
  const store = new MemoryStore();
  const log = new SessionEventLog("session-1", {
    store,
    now: () => new Date("2026-08-17T12:00:00Z"),
  });
  await Promise.all([
    log.append({ type: "turn_start", prompt: "inspect" }),
    log.append({ type: "user_message", message: { role: "user", content: "inspect" } }),
    log.append({ type: "assistant_message", message: { role: "assistant", content: "", toolCalls: [{ id: "c1", name: "read", arguments: "{}" }] } }),
    log.append({ type: "tool_call", call: { id: "c1", name: "read", arguments: "{}" } }),
    log.append({ type: "tool_result", message: { role: "tool", content: "ok", name: "read", toolCallId: "c1" } }),
  ]);

  assert.deepEqual(log.replay().map((record) => record.sequence), [1, 2, 3, 4, 5]);
  assert.deepEqual(log.deriveMessages().map((message) => message.role), ["user", "assistant", "tool"]);
  assert.equal((store.values.get(".luma/sessions/session-1.jsonl") ?? "").trim().split("\n").length, 5);
});

test("loads durable events and rejects broken sequences", async () => {
  const store = new MemoryStore();
  const log = new SessionEventLog("session-2", { store });
  await log.append({ type: "user_message", message: { role: "user", content: "hello" } });

  const restored = await SessionEventLog.load("session-2", { store });
  assert.equal(restored.lastSequence, 1);
  assert.equal(restored.deriveMessages()[0]?.content, "hello");

  store.values.set(".luma/sessions/broken.jsonl", JSON.stringify({
    schemaVersion: 1,
    sessionId: "broken",
    sequence: 2,
    timestamp: "2026-08-17T12:00:00.000Z",
    event: { type: "turn_start", prompt: "x" },
  }));
  await assert.rejects(SessionEventLog.load("broken", { store }), SessionEventLogError);
});

test("forks from a sequence boundary into an independent session", async () => {
  const source = new SessionEventLog("source");
  await source.append({ type: "user_message", message: { role: "user", content: "one" } });
  await source.append({ type: "assistant_message", message: { role: "assistant", content: "two" } });
  await source.append({ type: "user_message", message: { role: "user", content: "three" } });

  const fork = await source.fork("fork", 2);
  await fork.append({ type: "user_message", message: { role: "user", content: "branch" } });

  assert.deepEqual(fork.deriveMessages().map((message) => message.content), ["one", "two", "branch"]);
  assert.deepEqual(source.deriveMessages().map((message) => message.content), ["one", "two", "three"]);
});
