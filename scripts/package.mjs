import { readFile, writeFile, mkdir, cp, rm, readdir } from "node:fs/promises";
import { createHash } from "node:crypto";
import { relative } from "node:path";

const root = new URL("../", import.meta.url);
const pkg = JSON.parse(await readFile(new URL("package.json", root), "utf8"));
const manifest = JSON.parse(await readFile(new URL("version-manifest.json", root), "utf8"));
if (pkg.version !== manifest.version || Object.values(manifest.components).some((v) => v !== manifest.version)) throw new Error("版本清单与 package.json 不一致");
const releaseRoot = new URL("release/", root);
const target = new URL(`release/shelly-hermes-agent-v${pkg.version}/`, root);
await rm(releaseRoot, { recursive: true, force: true }); await mkdir(target, { recursive: true });
for (const path of ["dist", "hosts/windows", "docs", "schemas", "README.md", "package.json", "package-lock.json", "version-manifest.json", ".env.example"]) await cp(new URL(path, root), new URL(path, target), { recursive: true });
const lock = JSON.parse(await readFile(new URL("package-lock.json", root), "utf8"));
const components = Object.entries(lock.packages ?? {}).filter(([key]) => key && key !== "").map(([key, value]) => ({ type:"library", "bom-ref": key, name:key.replace(/^node_modules\//,""), version:value.version ?? "unknown", purl:`pkg:npm/${key.replace(/^node_modules\//,"")}@${value.version ?? "unknown"}` }));
await writeFile(new URL("sbom.cdx.json", target), JSON.stringify({ bomFormat:"CycloneDX", specVersion:"1.5", version:1, metadata:{component:{type:"application",name:pkg.name,version:pkg.version}}, components }, null, 2) + "\n");
const files = await walk(target); const sums = [];
for (const file of files) { const name = relative(target.pathname, file.pathname).replaceAll("\\", "/"); if (name === "SHA256SUMS") continue; sums.push(`${createHash("sha256").update(await readFile(file)).digest("hex")}  ${name}`); }
await writeFile(new URL("SHA256SUMS", target), sums.sort().join("\n") + "\n");
console.log(`release/shelly-hermes-agent-v${pkg.version}`);
async function walk(dir) { const out=[]; for (const e of await readdir(dir,{withFileTypes:true})) { const child=new URL(`${e.name}${e.isDirectory()?"/":""}`,dir); if(e.isDirectory()) out.push(...await walk(child)); else out.push(child); } return out; }
