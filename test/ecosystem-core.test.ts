import test from "node:test";
import assert from "node:assert/strict";
import { CodingAgent, TaskRollbackMachine, approveDiffByHunk, compressContext } from "../src/index.js";

test("context compression is deterministic and budget bounded", async () => {
  const result = await compressContext([
    { id: "b", content: "lower", priority: 1 },
    { id: "a", content: "higher", priority: 2 },
  ], { maxCharacters: 12, maxTokens: 12 }, undefined, { count: (text) => text.length });
  assert.equal(result.text, "[a]\nhigher\n\n");
  assert.equal(result.truncated, true);
});

test("CodingAgent injects optional recalled context", async () => {
  let seen = "";
  const agent = new CodingAgent({ complete: async (request) => {
    seen = request.messages.map((message) => message.content).join("|");
    return { message: { role: "assistant", content: "ok" } };
  } }, []);
  await agent.run("fix cache", { systemPrompt: "system", contextProvider: { provide: async () => [{ id: "rule", content: "invalidate first" }] } });
  assert.match(seen, /Recalled context/);
  assert.match(seen, /invalidate first/);
});

test("diff approval is hunk scoped and aborts", async () => {
  const result = await approveDiffByHunk("task", { id: "d", kind: "modify", oldPath: "a", newPath: "a", hunks: [
    { id: "h1", oldStart: 1, oldLines: 1, newStart: 1, newLines: 1, lines: [] },
    { id: "h2", oldStart: 2, oldLines: 1, newStart: 2, newLines: 1, lines: [] },
  ] }, { decide: async ({ ordinal }) => ordinal === 0 ? "approve" : "abort" });
  assert.deepEqual(result, { approvedHunkIds: ["h1"], rejectedHunkIds: [], aborted: true });
});

test("task checkpoint machine delegates rollback", async () => {
  const effects: string[] = [];
  const machine = new TaskRollbackMachine("task", {
    create: async (taskId) => ({ id: "cp", taskId, createdAt: "now" }),
    rollback: async ({ id }) => { effects.push(`rollback:${id}`); },
    discard: async () => { effects.push("discard"); },
  });
  assert.equal((await machine.begin()).state, "active");
  assert.equal((await machine.rollback()).state, "rolled_back");
  assert.deepEqual(effects, ["rollback:cp"]);
  await assert.rejects(() => machine.commit(), /Invalid checkpoint transition/);
});
