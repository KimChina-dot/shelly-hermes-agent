import { randomBytes, timingSafeEqual } from "node:crypto";
import { createReadStream } from "node:fs";
import { readFile, stat } from "node:fs/promises";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import type { HostConfig } from "./config.js";
import { redactConfig } from "./config.js";
import { probeModels } from "./health.js";
import { SessionStore } from "./sessions.js";

export interface ApprovalRequest { id:string; title:string; detail:string; diff?:string; status:"pending"|"approved"|"rejected"; createdAt:string }
export interface TaskLog { id:string; level:"info"|"warn"|"error"; message:string; createdAt:string }
export interface DesktopState { approvals:ApprovalRequest[]; logs:TaskLog[] }
export interface LocalServerOptions {
  sessions?:SessionStore; state?:DesktopState;
  onChat?:(sessionId:string,message:string)=>Promise<string>;
  onConfig?:(patch:Record<string,unknown>)=>Promise<void>;
  staticDir?:string;
}
const DEFAULT_STATIC=fileURLToPath(new URL("./web/",import.meta.url));
const MIME:Record<string,string>={".html":"text/html; charset=utf-8",".css":"text/css; charset=utf-8",".js":"text/javascript; charset=utf-8",".svg":"image/svg+xml"};

/** Zero-dependency desktop HTTP host. Authentication secrets are per-process and never written to disk. */
export function createLocalServer(config:HostConfig,options:LocalServerOptions={}):Server{
  if(config.host!=="127.0.0.1") throw new Error("桌面 API 只允许绑定 127.0.0.1");
  const sessionToken=randomBytes(32).toString("base64url"),csrfToken=randomBytes(32).toString("base64url");
  const sessions=options.sessions??new SessionStore(config.dataDir);
  const state=options.state??{approvals:[],logs:[]};
  return createServer(async(req,res)=>{
    securityHeaders(res);
    try{
      const url=new URL(req.url??"/","http://127.0.0.1");
      if(req.method==="GET"&&url.pathname==="/healthz") return json(res,200,{ok:true,pid:process.pid,uptime:process.uptime()});
      if(req.method==="GET"&&url.pathname==="/readyz"){const p=await probeModels(config);return json(res,p.ok?200:503,p);}
      if(req.method==="GET"&&url.pathname==="/"){
        const html=await readFile(join(options.staticDir??DEFAULT_STATIC,"index.html"),"utf8");
        res.setHeader("set-cookie",`shelly_session=${sessionToken}; HttpOnly; SameSite=Strict; Path=/`);
        res.setHeader("content-type",MIME[".html"]!);res.end(html.replace("__CSRF_TOKEN__",csrfToken));return;
      }
      if(url.pathname.startsWith("/assets/")) return serveAsset(res,options.staticDir??DEFAULT_STATIC,url.pathname.slice(8));
      if(url.pathname.startsWith("/api/")){
        if(!constantEqual(cookie(req,"shelly_session"),sessionToken)) return json(res,401,{error:"会话无效，请刷新桌面页面"});
        if(req.method!=="GET"&&!constantEqual(header(req,"x-shelly-csrf"),csrfToken)) return json(res,403,{error:"CSRF 校验失败"});
        if(req.method==="GET"&&url.pathname==="/api/bootstrap") return json(res,200,{config:redactConfig(config),health:{ok:true},sessions:await sessions.list(),approvals:state.approvals,logs:state.logs});
        if(req.method==="POST"&&url.pathname==="/api/sessions") return json(res,201,await sessions.create());
        const sessionMatch=/^\/api\/sessions\/([\w-]+)$/.exec(url.pathname);
        if(req.method==="GET"&&sessionMatch) return json(res,200,await sessions.load(sessionMatch[1]!));
        if(req.method==="POST"&&url.pathname==="/api/chat"){
          const body=await bodyJson(req),message=text(body.message,"message",20_000);let id=typeof body.sessionId==="string"?body.sessionId:"";
          const session=id?await sessions.load(id):await sessions.create();id=session.id;session.messages.push({role:"user",content:message});
          const answer=options.onChat?await options.onChat(id,message):"桌面主机已收到消息；请配置 Agent 运行器。";
          session.messages.push({role:"assistant",content:answer});await sessions.save(session);
          state.logs.unshift({id:randomBytes(8).toString("hex"),level:"info",message:`会话 ${id} 完成`,createdAt:new Date().toISOString()});
          return json(res,200,{sessionId:id,answer});
        }
        if(req.method==="PATCH"&&url.pathname==="/api/config"){const b=await bodyJson(req);await options.onConfig?.(b);return json(res,200,{ok:true});}
        const approval=/^\/api\/approvals\/([\w-]+)\/(approve|reject)$/.exec(url.pathname);
        if(req.method==="POST"&&approval){const item=state.approvals.find(x=>x.id===approval[1]);if(!item)return json(res,404,{error:"审批不存在"});if(item.status!=="pending")return json(res,409,{error:"审批已处理"});item.status=approval[2]==="approve"?"approved":"rejected";return json(res,200,item);}
        return json(res,404,{error:"API 不存在"});
      }
      return json(res,404,{error:"not found"});
    }catch(error){const code=(error as NodeJS.ErrnoException).code;json(res,code==="ENOENT"?404:400,{error:error instanceof Error?error.message:String(error)});}
  });
}
export async function listen(server:Server,config:HostConfig):Promise<void>{if(config.host!=="127.0.0.1")throw new Error("拒绝非回环地址");await new Promise<void>((resolve,reject)=>{server.once("error",reject);server.listen(config.port,"127.0.0.1",()=>{server.off("error",reject);resolve();});});}
export async function close(server:Server):Promise<void>{if(!server.listening)return;await new Promise<void>((resolve,reject)=>server.close(e=>e?reject(e):resolve()));}
function securityHeaders(res:ServerResponse){res.setHeader("cache-control","no-store");res.setHeader("x-content-type-options","nosniff");res.setHeader("x-frame-options","DENY");res.setHeader("referrer-policy","no-referrer");res.setHeader("content-security-policy","default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'");}
function json(res:ServerResponse,status:number,value:unknown){res.statusCode=status;res.setHeader("content-type","application/json; charset=utf-8");res.end(JSON.stringify(value));}
async function serveAsset(res:ServerResponse,root:string,name:string){const safe=normalize(name).replace(/^(\.\.(\/|\\|$))+/,"");const path=join(root,safe);if(!path.startsWith(normalize(root)))return json(res,403,{error:"invalid path"});const info=await stat(path);if(!info.isFile())return json(res,404,{error:"not found"});res.setHeader("content-type",MIME[extname(path)]??"application/octet-stream");res.setHeader("cache-control","public, max-age=3600");createReadStream(path).pipe(res);}
async function bodyJson(req:IncomingMessage):Promise<Record<string,unknown>>{let raw="";for await(const chunk of req){raw+=chunk;if(raw.length>1_000_000)throw new Error("请求体过大");}if(!raw)return {};const value=JSON.parse(raw) as unknown;if(!value||typeof value!=="object"||Array.isArray(value))throw new Error("请求体必须是 JSON 对象");return value as Record<string,unknown>;}
function cookie(req:IncomingMessage,name:string){for(const part of (req.headers.cookie??"").split(";")){const [key,...value]=part.trim().split("=");if(key===name)return value.join("=");}return "";}
function header(req:IncomingMessage,name:string){const value=req.headers[name];return Array.isArray(value)?value[0]??"":value??"";}
function constantEqual(a:string,b:string){const aa=Buffer.from(a),bb=Buffer.from(b);return aa.length===bb.length&&timingSafeEqual(aa,bb);}
function text(value:unknown,name:string,max:number){if(typeof value!=="string"||!value.trim())throw new Error(`${name} 不能为空`);if(value.length>max)throw new Error(`${name} 过长`);return value.trim();}
