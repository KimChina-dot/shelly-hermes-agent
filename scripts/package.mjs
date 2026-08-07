import { cp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { relative } from "node:path";

const root = new URL("../", import.meta.url);
const pkg = JSON.parse(await readFile(new URL("package.json", root), "utf8"));
const releaseRoot = new URL("release/", root);
const target = new URL(`release/shelly-hermes-agent-v${pkg.version}/`, root);
await rm(releaseRoot, { recursive: true, force: true });
await mkdir(target, { recursive: true });

for (const path of ["dist", "hosts/windows", "docs", "README.md", "package.json", "package-lock.json", ".env.example"]) {
  await cp(new URL(path, root), new URL(path, target), { recursive: true });
}

const files = await walk(new URL(".", target));
const sums = [];
for (const file of files.filter((url) => !url.pathname.endsWith("SHA256SUMS"))) {
  const data = await readFile(file);
  sums.push(`${createHash("sha256").update(data).digest("hex")}  ${relative(target.pathname, file.pathname).replaceAll("\\", "/")}`);
}
await writeFile(new URL("SHA256SUMS", target), `${sums.sort().join("\n")}\n`, "utf8");
console.log(`release/shelly-hermes-agent-v${pkg.version}`);

async function walk(dir) {
  const out = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const child = new URL(`${entry.name}${entry.isDirectory() ? "/" : ""}`, dir);
    if (entry.isDirectory()) out.push(...await walk(child));
    else out.push(child);
  }
  return out;
}
