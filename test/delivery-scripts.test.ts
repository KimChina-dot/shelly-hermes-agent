import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";

const root = new URL("../", import.meta.url);
test("统一版本清单与升级 schema 基础有效", async () => {
  const pkg=JSON.parse(await readFile(new URL("package.json",root),"utf8"));
  const manifest=JSON.parse(await readFile(new URL("version-manifest.json",root),"utf8"));
  assert.equal(manifest.version,pkg.version); assert.deepEqual(new Set(Object.values(manifest.components)),new Set([pkg.version]));
  const schema=JSON.parse(await readFile(new URL("schemas/update-channel.schema.json",root),"utf8")); assert.equal(schema.properties.schemaVersion.const,1);
});
test("发布门禁拒绝组件版本漂移", async () => {
  const dir=await mkdtemp(join(tmpdir(),"shelly-gate-"));
  const manifest=JSON.parse(await readFile(new URL("version-manifest.json",root),"utf8")); manifest.components.core="9.9.9";
  await writeFile(join(dir,"manifest.json"),JSON.stringify(manifest));
  assert.throws(() => execFileSync(process.execPath,["scripts/release-gate.mjs"],{cwd:new URL("../",import.meta.url),env:{...process.env,SHELLY_VERSION_MANIFEST:join(dir,"manifest.json")},stdio:"pipe"}));
});
test("发布门禁在仓库状态通过", () => {
  const output=execFileSync(process.execPath,["scripts/release-gate.mjs"],{cwd:new URL("../",import.meta.url),encoding:"utf8"}); assert.match(output,/PASS/);
});
