import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, isAbsolute, resolve } from "node:path";

export type LogLevel = "debug" | "info" | "warn" | "error";
export interface HostConfig {
  baseUrl: string; apiKey: string; model: string; workspace: string;
  dataDir: string; logLevel: LogLevel; timeoutMs: number;
  maxTurns: number; maxToolCalls: number; host: string; port: number;
}
export interface LoadConfigOptions { cwd?: string; env?: NodeJS.ProcessEnv; args?: readonly string[]; configPath?: string; }

const defaults: HostConfig = {
  baseUrl: "http://127.0.0.1:11434/v1", apiKey: "local", model: "",
  workspace: process.cwd(), dataDir: resolve(homedir(), ".shelly"), logLevel: "info",
  timeoutMs: 120_000, maxTurns: 12, maxToolCalls: 24, host: "127.0.0.1", port: 43821,
};

/** Load defaults < JSON config < .env < process env < CLI flags. */
export async function loadHostConfig(options: LoadConfigOptions = {}): Promise<HostConfig> {
  const cwd = resolve(options.cwd ?? process.cwd());
  const env = options.env ?? process.env;
  const args = parseArgs(options.args ?? []);
  const configPath = resolve(cwd, options.configPath ?? args.config ?? env.SHELLY_CONFIG ?? "shelly.config.json");
  const json = await optionalJson(configPath);
  const dotenv = await optionalText(resolve(dirname(configPath), ".env"));
  const merged = { ...defaults, ...json, ...fromEnv(parseDotenv(dotenv)), ...fromEnv(env), ...fromArgs(args) } as Record<string, unknown>;
  const config: HostConfig = {
    baseUrl: string(merged.baseUrl, "baseUrl").replace(/\/+$/, ""),
    apiKey: string(merged.apiKey || "local", "apiKey"), model: typeof merged.model === "string" ? merged.model.trim() : "",
    workspace: path(merged.workspace, cwd), dataDir: path(merged.dataDir, cwd),
    logLevel: level(merged.logLevel), timeoutMs: integer(merged.timeoutMs, "timeoutMs", 1),
    maxTurns: integer(merged.maxTurns, "maxTurns", 1), maxToolCalls: integer(merged.maxToolCalls, "maxToolCalls", 0),
    host: string(merged.host, "host"), port: integer(merged.port, "port", 1, 65535),
  };
  try { new URL(config.baseUrl); } catch { throw new Error(`baseUrl 不是有效 URL: ${config.baseUrl}`); }
  return config;
}

export function redactConfig(config: HostConfig): Record<string, unknown> {
  return { ...config, apiKey: config.apiKey ? "***" : "" };
}

function parseArgs(args: readonly string[]): Record<string, string> {
  const out: Record<string, string> = {};
  for (let i = 0; i < args.length; i++) {
    const item = args[i]!; if (!item.startsWith("--")) continue;
    const eq = item.indexOf("="); const key = camel(item.slice(2, eq < 0 ? undefined : eq));
    const value = eq >= 0 ? item.slice(eq + 1) : args[i + 1] && !args[i + 1]!.startsWith("--") ? args[++i]! : "true";
    out[key] = value;
  }
  return out;
}
function fromArgs(a: Record<string, string>): Record<string, unknown> { const { config: _, ...rest } = a; return rest; }
function fromEnv(e: NodeJS.ProcessEnv | Record<string, string>): Record<string, unknown> {
  const map: Record<string, string> = { SHELLY_BASE_URL:"baseUrl", SHELLY_API_KEY:"apiKey", SHELLY_MODEL:"model", SHELLY_WORKSPACE:"workspace", SHELLY_DATA_DIR:"dataDir", SHELLY_LOG_LEVEL:"logLevel", SHELLY_TIMEOUT_MS:"timeoutMs", SHELLY_MAX_TURNS:"maxTurns", SHELLY_MAX_TOOL_CALLS:"maxToolCalls", SHELLY_HOST:"host", SHELLY_PORT:"port" };
  const out: Record<string, unknown> = {}; for (const [k,v] of Object.entries(map)) if (e[k] !== undefined && e[k] !== "") out[v] = e[k]; return out;
}
function parseDotenv(text: string): Record<string,string> { const out: Record<string,string>={}; for(const raw of text.split(/\r?\n/)){ const line=raw.trim(); if(!line||line.startsWith("#")) continue; const m=/^(?:export\s+)?([A-Za-z_][\w]*)\s*=\s*(.*)$/.exec(line); if(!m) continue; let v=m[2]!.trim(); if((v.startsWith('"')&&v.endsWith('"'))||(v.startsWith("'")&&v.endsWith("'"))) v=v.slice(1,-1); out[m[1]!]=v.replace(/\\n/g,"\n"); } return out; }
async function optionalText(p:string):Promise<string>{ try{return await readFile(p,"utf8");}catch(e){if((e as NodeJS.ErrnoException).code==="ENOENT")return "";throw e;} }
async function optionalJson(p:string):Promise<Record<string,unknown>>{const t=await optionalText(p);if(!t)return {};try{return JSON.parse(t) as Record<string,unknown>;}catch{throw new Error(`配置文件 JSON 无效: ${p}`);}}
function camel(v:string){return v.replace(/-([a-z])/g,(_,c:string)=>c.toUpperCase());}
function string(v:unknown,n:string){if(typeof v!=="string"||!v.trim())throw new Error(`${n} 不能为空`);return v.trim();}
function path(v:unknown,cwd:string){const s=string(v,"path");return resolve(isAbsolute(s)?s:resolve(cwd,s));}
function integer(v:unknown,n:string,min:number,max=Number.MAX_SAFE_INTEGER){const x=typeof v==="number"?v:Number(v);if(!Number.isInteger(x)||x<min||x>max)throw new Error(`${n} 必须是 ${min}..${max} 的整数`);return x;}
function level(v:unknown):LogLevel{if(v==="debug"||v==="info"||v==="warn"||v==="error")return v;throw new Error("logLevel 必须是 debug/info/warn/error");}
