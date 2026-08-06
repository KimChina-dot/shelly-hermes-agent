import assert from "node:assert/strict";
import test from "node:test";
import { PluginRegistry, PluginRegistryError, type Blade } from "../src/plugins/index.js";
const makeBlade = (invoke: Blade["invoke"]): Blade => ({ manifest: { id: "demo", version: "1", capabilities: ["fs.read"] }, invoke });
test("starts and invokes authorized blade", async () => { const r = new PluginRegistry(); r.register(makeBlade((_c, input) => input)); await r.start("demo"); assert.equal(await r.invoke("demo", "fs.read", "ok"), "ok"); });
test("rejects undeclared capability", async () => { const r = new PluginRegistry(); r.register(makeBlade(() => "bad")); await r.start("demo"); await assert.rejects(r.invoke("demo", "fs.write"), (e: unknown) => e instanceof PluginRegistryError && e.code === "CAPABILITY_DENIED"); });
test("opens circuit after timeout", async () => { let now = 0; const r = new PluginRegistry({ timeoutMs: 5, failureThreshold: 1, circuitResetMs: 10, now: () => now }); r.register(makeBlade(() => new Promise(() => undefined))); await r.start("demo"); await assert.rejects(r.invoke("demo", "fs.read"), /timed out/); assert.equal(r.status("demo").circuit, "open"); now = 10; assert.equal(r.status("demo").circuit, "half-open"); });
