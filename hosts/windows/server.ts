import { createServer, type Server } from "node:http";
import type { HostConfig } from "./config.js";
import { probeModels } from "./health.js";
export function createLocalServer(config:HostConfig):Server{return createServer(async(req,res)=>{res.setHeader("content-type","application/json; charset=utf-8");res.setHeader("cache-control","no-store");if(req.method==="GET"&&req.url==="/healthz"){res.end(JSON.stringify({ok:true,pid:process.pid,uptime:process.uptime()}));return;}if(req.method==="GET"&&req.url==="/readyz"){const p=await probeModels(config);res.statusCode=p.ok?200:503;res.end(JSON.stringify(p));return;}res.statusCode=404;res.end(JSON.stringify({error:"not found"}));});}
export async function listen(server:Server,config:HostConfig):Promise<void>{await new Promise<void>((resolve,reject)=>{server.once("error",reject);server.listen(config.port,config.host,()=>{server.off("error",reject);resolve();});});}
export async function close(server:Server):Promise<void>{if(!server.listening)return;await new Promise<void>((resolve,reject)=>server.close(e=>e?reject(e):resolve()));}
