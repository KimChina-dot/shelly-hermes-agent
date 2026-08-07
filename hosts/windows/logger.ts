import { appendFile, mkdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import type { LogLevel } from "./config.js";
const ranks: Record<LogLevel,number>={debug:10,info:20,warn:30,error:40};
export class JsonLogger {
  readonly file: string;
  constructor(dataDir:string,private readonly minimum:LogLevel="info",private readonly stderr:Pick<NodeJS.WriteStream,"write">=process.stderr){this.file=join(dataDir,"logs","shelly.jsonl");}
  async log(level:LogLevel,message:string,fields:Record<string,unknown>={}):Promise<void>{if(ranks[level]<ranks[this.minimum])return;const row=JSON.stringify({time:new Date().toISOString(),level,message,...sanitize(fields)})+"\n";await mkdir(dirname(this.file),{recursive:true});await appendFile(this.file,row,"utf8");if(level==="warn"||level==="error")this.stderr.write(`[${level}] ${message}\n`);}
}
function sanitize(value:Record<string,unknown>):Record<string,unknown>{const out:Record<string,unknown>={};for(const[k,v]of Object.entries(value))out[k]=/key|token|authorization|secret/i.test(k)?"***":v;return out;}
