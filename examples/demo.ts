import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CheckpointStore } from "../src/checkpoint/index.js";
import { HermesMemorySystem } from "../src/hermes/index.js";
import { MinimalKernel, type KernelStep } from "../src/kernel/index.js";
import { NodeProcessAdapter, NodeTextStore } from "../src/adapters/node/index.js";
import { SafeFileTools } from "../src/tools/index.js";

const root = await mkdtemp(join(tmpdir(), "shelly-hermes-e2e-"));
try {
  const store = new NodeTextStore(root);
  const files = new SafeFileTools(store, "/project", { read: true, write: true });
  const processes = new NodeProcessAdapter(root);
  await files.write("app.mjs", "export const add = (a, b) => a - b;\n");
  const checkpoints = new CheckpointStore<any>(store, 1);
  const plan = { id: "repair-demo", steps: [{ id: "patch" }, { id: "test" }, { id: "remember" }] };
  const kernel = new MinimalKernel({
    checkpoints,
    budget: { maxSteps: 5, maxToolCalls: 5, maxTokens: 1000 },
    executor: { execute: async (step: KernelStep) => {
      if (step.id === "patch") {
        await files.applyPatch("app.mjs", "a - b", "a + b");
        return { output: "patched", toolCalls: 1, tokens: 20 };
      }
      if (step.id === "test") {
        const result = await processes.run({ executable: process.execPath, args: ["-e", "import('./project/app.mjs').then(m=>{if(m.add(2,3)!==5)process.exit(1);console.log('test-ok')})"], cwd: root, timeoutMs: 2000, maxOutputBytes: 2048 });
        if (result.exitCode !== 0) throw new Error(result.stderr || "test failed");
        return { output: result.stdout.trim(), toolCalls: 1, tokens: 20 };
      }
      const hermes = new HermesMemorySystem({ store, clock: { now: () => new Date() } });
      await hermes.upsert({ id: "repair-arithmetic", title: "Repair arithmetic by exact patch", truth: "Patch context must match exactly once", action: "Run a focused test after patching", tags: ["patch", "test"] });
      return { output: "remembered", toolCalls: 1, tokens: 20 };
    }},
  });
  const final = await kernel.run(plan);
  console.log(JSON.stringify({ status: final.status, completed: final.completedStepIds, source: await files.read("app.mjs"), knowledge: await store.exists(".shelly/knowledge.json") }));
} finally {
  await rm(root, { recursive: true, force: true });
}
