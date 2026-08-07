import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { NodeProcessAdapter, NodeTextStore } from "../src/adapters/node/index.js";
import { createWorkspaceTools } from "../src/tools/index.js";

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "shelly-tools-"));
  const tools = createWorkspaceTools({
    root,
    store: new NodeTextStore(root),
    process: new NodeProcessAdapter(root),
  });
  return { root, byName: new Map(tools.map((tool) => [tool.definition.name, tool])) };
}

const denied = { confirm: async () => false };
const approved = { confirm: async () => true };

test("reads and lists files inside workspace", async () => {
  const { root, byName } = await fixture();
  await writeFile(join(root, "hello.txt"), "你好", "utf8");
  const read = await byName.get("read_file")?.execute({ path: "hello.txt" }, denied) as any;
  assert.equal(read.content, "你好");
  const list = await byName.get("list_files")?.execute({ path: "", recursive: false }, denied) as any;
  assert.deepEqual(list.entries, ["hello.txt"]);
});

test("requires approval before writing a file", async () => {
  const { root, byName } = await fixture();
  const tool = byName.get("write_file");
  await assert.rejects(tool?.execute({ path: "a.txt", content: "x" }, denied) ?? Promise.resolve(), /denied/);
  await tool?.execute({ path: "a.txt", content: "ok" }, approved);
  assert.equal(await readFile(join(root, "a.txt"), "utf8"), "ok");
});

test("requires approval and runs a command without shell expansion", async () => {
  const { byName } = await fixture();
  const tool = byName.get("run_command");
  await assert.rejects(
    tool?.execute({ executable: process.execPath, args: ["-e", "console.log('x')"], cwd: "" }, denied)
      ?? Promise.resolve(),
    /denied/,
  );
  const result = await tool?.execute(
    { executable: process.execPath, args: ["-e", "console.log(process.argv[1])", "a;echo hacked"], cwd: "" },
    approved,
  ) as any;
  assert.equal(result.exitCode, 0);
  assert.equal(result.stdout.trim(), "a;echo hacked");
});

test("rejects paths outside workspace", async () => {
  const { byName } = await fixture();
  await assert.rejects(
    byName.get("read_file")?.execute({ path: "../secret" }, denied) ?? Promise.resolve(),
    /outside|escapes/i,
  );
});
