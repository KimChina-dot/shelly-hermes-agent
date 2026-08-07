import { readFile } from "node:fs/promises";
const lock = JSON.parse(await readFile(new URL("../package-lock.json", import.meta.url), "utf8"));
const packages = Object.entries(lock.packages ?? {}).filter(([key]) => key);
console.log(JSON.stringify({ tool:"npm-audit-baseline", generatedBy:"scripts/dependency-audit.mjs", packageLockVersion:lock.lockfileVersion, dependencies:packages.map(([path,p])=>({path,name:path.replace(/^node_modules\//,""),version:p.version,dev:!!p.dev})) }, null, 2));
