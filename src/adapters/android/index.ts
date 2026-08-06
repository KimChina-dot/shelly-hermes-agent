import type { BackgroundTaskPort, NotificationPort, ProcessPort, ProcessRequest, ProcessResult, TextStorePort } from "../../core/ports.js";
export interface AndroidHostBindings {
  readText(path:string):Promise<string|null>;
  writeTextAtomic(path:string,content:string):Promise<void>;
  appendText(path:string,content:string):Promise<void>;
  exists(path:string):Promise<boolean>;
  runProcess(request:ProcessRequest):Promise<ProcessResult>;
  scheduleTask(taskId:string,payload:string):Promise<void>;
  cancelTask(taskId:string):Promise<void>;
  notify(event:{kind:"progress"|"completion";taskId:string;title:string;progress?:number;summary?:string}):Promise<void>;
}
const pathOk=(p:string)=>{if(!p.trim()||p.includes("\0"))throw new Error("Invalid path");};
const idOk=(id:string)=>{if(!/^[A-Za-z0-9._-]{1,128}$/.test(id))throw new Error("Invalid task id");};
export class AndroidHostBridge implements TextStorePort,ProcessPort,BackgroundTaskPort,NotificationPort{
 constructor(private readonly native:AndroidHostBindings){}
 async read(p:string){pathOk(p);return (await this.native.readText(p))??undefined}
 async writeAtomic(p:string,c:string){pathOk(p);await this.native.writeTextAtomic(p,c)}
 async append(p:string,c:string){pathOk(p);await this.native.appendText(p,c)}
 async exists(p:string){pathOk(p);return this.native.exists(p)}
 async run(r:ProcessRequest){if(!r.executable.trim()||r.timeoutMs<=0||r.maxOutputBytes<=0)throw new Error("Invalid process request");return this.native.runProcess(r)}
 async schedule(id:string,payload:string){idOk(id);JSON.parse(payload);await this.native.scheduleTask(id,payload)}
 async cancel(id:string){idOk(id);await this.native.cancelTask(id)}
 async showProgress(id:string,title:string,progress?:number){idOk(id);if(progress!==undefined&&(progress<0||progress>1))throw new Error("Invalid progress");await this.native.notify({kind:"progress",taskId:id,title,...(progress===undefined?{}:{progress})})}
 async showCompletion(id:string,title:string,summary:string){idOk(id);await this.native.notify({kind:"completion",taskId:id,title,summary})}
}
