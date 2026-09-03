import assert from "node:assert/strict";
import test from "node:test";
import { AgentTaskQueue, type AgentTask } from "../src/agent/index.js";

test("runs queued tasks in four-slot waves", async () => {
  const started: string[] = [];
  const tasks = Array.from({ length: 9 }, (_, index): AgentTask<string> => ({
    id: `task-${index + 1}`,
    async run(context) {
      started.push(`${context.wave}:${context.slot}:${index + 1}`);
      return `done-${index + 1}`;
    },
  }));
  const logs: string[] = [];
  const queue = new AgentTaskQueue(tasks, { logger: { log: (line) => logs.push(line) } });
  const result = await queue.run();
  assert.deepEqual(started, ["1:1:1", "1:2:2", "1:3:3", "1:4:4", "2:1:5", "2:2:6", "2:3:7", "2:4:8", "3:1:9"]);
  assert.equal(result.progress.succeeded, 9);
  assert.equal(result.progress.completed, 9);
  assert.equal(result.progress.activeWave, 3);
  assert.match(logs[0] ?? "", /queue:start/);
  assert.match(logs.at(-1) ?? "", /queue:finish/);
});

test("retries failures and records exhausted tasks", async () => {
  let flakyAttempts = 0;
  const queue = new AgentTaskQueue<string>([
    {
      id: "flaky",
      async run() {
        flakyAttempts += 1;
        if (flakyAttempts === 1) throw new Error("try again");
        return "ok";
      },
    },
    {
      id: "broken",
      async run() {
        throw new Error("still broken");
      },
    },
  ], { maxRetries: 1 });
  const result = await queue.run();
  const flaky = result.checkpoint.tasks.find((task) => task.id === "flaky");
  const broken = result.checkpoint.tasks.find((task) => task.id === "broken");
  assert.equal(flaky?.status, "succeeded");
  assert.equal(flaky?.attempts, 2);
  assert.equal(broken?.status, "exhausted");
  assert.equal(broken?.attempts, 2);
  assert.equal(result.progress.failed, 1);
});

test("resumes from checkpoints without replaying finished tasks", async () => {
  const ran: string[] = [];
  const tasks: AgentTask<string>[] = [
    { id: "done", async run() { ran.push("done"); return "new"; } },
    { id: "running", async run() { ran.push("running"); return "resumed"; } },
    { id: "queued", async run() { ran.push("queued"); return "fresh"; } },
  ];
  const queue = new AgentTaskQueue(tasks, {
    checkpoint: {
      schemaVersion: 1,
      tasks: [
        { id: "done", status: "succeeded", attempts: 1, wave: 1, slot: 1, output: "old", updatedAt: "2026-08-14T00:00:00.000Z" },
        { id: "running", status: "running", attempts: 1, wave: 1, slot: 2, updatedAt: "2026-08-14T00:00:00.000Z" },
      ],
    },
  });
  const result = await queue.run();
  assert.deepEqual(ran, ["running", "queued"]);
  assert.equal(result.checkpoint.tasks.find((task) => task.id === "done")?.output, "old");
  assert.equal(result.progress.completed, 3);
});
