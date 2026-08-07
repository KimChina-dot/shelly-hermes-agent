import { mkdir, readFile, readdir, rename, writeFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { join } from "node:path";
import type { ChatMessage } from "../../src/agent/types.js";
export interface Session { id:string; createdAt:string; updatedAt:string; messages:ChatMessage[]; }
export class SessionStore {
  private readonly dir:string;
  constructor(dataDir:string){this.dir=join(dataDir,"sessions");}
  async create():Promise<Session>{const now=new Date().toISOString();const s={id:randomUUID(),createdAt:now,updatedAt:now,messages:[]};await this.save(s);return s;}
  async load(id:string):Promise<Session>{if(!/^[\w-]+$/.test(id))throw new Error("会话 ID 无效");return JSON.parse(await readFile(join(this.dir,`${id}.json`),"utf8")) as Session;}
  async save(session:Session):Promise<void>{await mkdir(this.dir,{recursive:true});const value={...session,updatedAt:new Date().toISOString()};const dest=join(this.dir,`${session.id}.json`),tmp=`${dest}.${process.pid}.tmp`;await writeFile(tmp,JSON.stringify(value,null,2),"utf8");await rename(tmp,dest);session.updatedAt=value.updatedAt;}
  async list():Promise<Array<Pick<Session,"id"|"createdAt"|"updatedAt">>>{await mkdir(this.dir,{recursive:true});const names=(await readdir(this.dir)).filter(x=>x.endsWith(".json"));const result=[];for(const n of names){try{const s=await this.load(n.slice(0,-5));result.push({id:s.id,createdAt:s.createdAt,updatedAt:s.updatedAt});}catch{}}return result.sort((a,b)=>b.updatedAt.localeCompare(a.updatedAt));}
}
