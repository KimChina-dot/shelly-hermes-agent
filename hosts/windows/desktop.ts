import { spawn } from "node:child_process";
import { loadHostConfig } from "./config.js";
import { close, createLocalServer, listen } from "./server.js";
const config=await loadHostConfig({args:process.argv.slice(2)});
const server=createLocalServer(config);
await listen(server,config);
const url=`http://127.0.0.1:${config.port}/`;
console.log(`Shelly Desktop: ${url}`);
if(!process.argv.includes("--no-open")){
  const command:readonly [string,readonly string[]]=process.platform==="win32"?["cmd",["/c","start","",url]]:process.platform==="darwin"?["open",[url]]:["xdg-open",[url]];
  spawn(command[0],command[1],{detached:true,stdio:"ignore"}).unref();
}
const stop=()=>void close(server).then(()=>process.exit());process.on("SIGINT",stop);process.on("SIGTERM",stop);
