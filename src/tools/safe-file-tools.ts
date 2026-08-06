import type { TextStorePort } from "../core/ports.js";
import { resolveSandboxPath } from "./logical-path.js";
export interface FileAuthorization { readonly read:boolean; readonly write:boolean; }
export class SafeFileTools {
  constructor(private readonly store:TextStorePort, private readonly root:string, private readonly auth:FileAuthorization) {}
  async read(path:string):Promise<string|undefined>{ if(!this.auth.read) throw new Error("fs.read capability required"); return this.store.read(resolveSandboxPath(this.root,path)); }
  async write(path:string,content:string):Promise<void>{ if(!this.auth.write) throw new Error("fs.write capability required"); await this.store.writeAtomic(resolveSandboxPath(this.root,path),content); }
  async applyPatch(path:string,expected:string,replacement:string):Promise<void>{ if(!this.auth.write) throw new Error("fs.write capability required"); if(!expected) throw new Error("Patch context must not be empty"); const target=resolveSandboxPath(this.root,path); const current=await this.store.read(target); if(current===undefined) throw new Error("Patch target not found"); const first=current.indexOf(expected); if(first<0 || current.indexOf(expected,first+expected.length)>=0) throw new Error("Patch context must match exactly once"); await this.store.writeAtomic(target,current.slice(0,first)+replacement+current.slice(first+expected.length)); }
}
