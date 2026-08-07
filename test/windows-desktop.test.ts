import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AddressInfo } from "node:net";
import { loadHostConfig } from "../hosts/windows/config.js";
import { close, createLocalServer, listen } from "../hosts/windows/server.js";

test("desktop host serves assets and protects API with session and CSRF",async()=>{
 const dir=await mkdtemp(join(tmpdir(),"shelly-desktop-"));
 const config=await loadHostConfig({env:{SHELLY_DATA_DIR:dir,SHELLY_WORKSPACE:dir,SHELLY_MODEL:"test",SHELLY_PORT:"1"},args:[]});config.port=0;
 const server=createLocalServer(config);await listen(server,config);const port=(server.address() as AddressInfo).port,base=`http://127.0.0.1:${port}`;
 try{
  const page=await fetch(base);assert.equal(page.status,200);assert.match(await page.text(),/Shelly Desktop/);const cookie=page.headers.get("set-cookie")?.split(";",1)[0]??"";
  assert.equal((await fetch(`${base}/api/bootstrap`)).status,401);
  const denied=await fetch(`${base}/api/sessions`,{method:"POST",headers:{cookie}});assert.equal(denied.status,403);
  const page2=await fetch(base,{headers:{cookie}});const html=await page2.text(),csrf=/<meta name="shelly-csrf" content="([^"]+)"/.exec(html)?.[1]??"";assert.ok(csrf);
  const created=await fetch(`${base}/api/sessions`,{method:"POST",headers:{cookie,"x-shelly-csrf":csrf}});assert.equal(created.status,201);
  const bootstrap=await fetch(`${base}/api/bootstrap`,{headers:{cookie}});assert.equal(bootstrap.status,200);assert.equal((await bootstrap.json()).config.apiKey,"***");
  const asset=await fetch(`${base}/assets/app.js`);assert.equal(asset.status,200);assert.match(asset.headers.get("content-type")??"",/javascript/);
 }finally{await close(server)}
});
test("desktop configuration rejects non-loopback binding",async()=>{await assert.rejects(()=>loadHostConfig({env:{SHELLY_HOST:"0.0.0.0"},args:[]}),/127\.0\.0\.1/)});
