import { readdir } from "node:fs/promises";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const files = (await readdir(new URL("../test/", import.meta.url), { withFileTypes: true }))
  .filter((entry) => entry.isFile() && entry.name.endsWith(".test.ts"))
  .map((entry) => fileURLToPath(new URL(`../test/${entry.name}`, import.meta.url)))
  .sort();

if (files.length === 0) throw new Error("No test files found");
const child = spawn(process.execPath, ["--import", "tsx", "--test", ...files], {
  stdio: "inherit",
  shell: false,
});
child.on("error", (error) => {
  console.error(error);
  process.exitCode = 1;
});
child.on("exit", (code, signal) => {
  if (signal) {
    console.error(`Test process terminated by ${signal}`);
    process.exitCode = 1;
  } else {
    process.exitCode = code ?? 1;
  }
});
