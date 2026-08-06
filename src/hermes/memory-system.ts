import type { ClockPort, TextStorePort } from "../core/ports.js";
import type { HermesSnapshot, KnowledgeEntry, KnowledgeInput, RankedKnowledge } from "./types.js";
export interface HermesOptions { readonly store:TextStorePort; readonly clock:ClockPort; readonly path?:string; }
export class HermesMemorySystem {
 private readonly entries=new Map<string,KnowledgeEntry>(); private readonly path:string;
 constructor(private readonly options:HermesOptions){this.path=options.path??".shelly/knowledge.json";}
 async load(){const raw=await this.options.store.read(this.path); if(!raw)return; const s=JSON.parse(raw) as HermesSnapshot; if(s.schemaVersion!==1||!Array.isArray(s.entries))throw new Error("Unsupported Hermes snapshot"); this.entries.clear(); for(const e of s.entries)this.entries.set(e.id,e);}
 list():readonly KnowledgeEntry[]{return [...this.entries.values()];}
 async upsert(input:KnowledgeInput){validate(input); const old=this.entries.get(input.id); const now=this.options.clock.now().toISOString(); const entry:KnowledgeEntry={id:input.id,title:input.title.trim(),truth:input.truth.trim(),action:input.action.trim(),tags:unique(input.tags??[]),tier:input.tier??old?.tier??"stable",confidence:clamp(input.confidence??old?.confidence??.8),createdAt:old?.createdAt??now,lastTriggeredAt:old?.lastTriggeredAt??now,triggerCount:old?.triggerCount??0}; this.entries.set(entry.id,entry); await this.persist(); return entry;}
 async touch(id:string){const old=this.require(id); const entry:KnowledgeEntry={...old,lastTriggeredAt:this.options.clock.now().toISOString(),triggerCount:old.triggerCount+1}; this.entries.set(id,entry); await this.persist(); return entry;}
 retrieve(query:string,limit=5):readonly RankedKnowledge[]{const terms=tokenize(query),now=this.options.clock.now().getTime(); return [...this.entries.values()].map(entry=>({entry,score:rank(entry,terms,now)})).filter(x=>x.score>0).sort((a,b)=>b.score-a.score).slice(0,Math.max(0,limit));}
 async evict(maxEntries:number){if(maxEntries<0)throw new RangeError("maxEntries must be non-negative"); const now=this.options.clock.now().getTime(); const candidates=[...this.entries.values()].filter(e=>e.tier!=="pinned").sort((a,b)=>rank(a,[],now)-rank(b,[],now)); const removed:KnowledgeEntry[]=[]; while(this.entries.size>maxEntries&&candidates.length){const e=candidates.shift();if(!e)break;this.entries.delete(e.id);removed.push(e);} if(removed.length)await this.persist(); return removed;}
 private require(id:string){const e=this.entries.get(id);if(!e)throw new Error(`Knowledge '${id}' not found`);return e;}
 private async persist(){const s:HermesSnapshot={schemaVersion:1,entries:this.list()};await this.options.store.writeAtomic(this.path,JSON.stringify(s,null,2)+"\n");}
}
function rank(e:KnowledgeEntry,terms:readonly string[],now:number){const words=tokenize(`${e.title} ${e.truth} ${e.action} ${e.tags.join(" ")}`);const relevance=terms.length?terms.filter(t=>words.includes(t)).length/terms.length:0;const days=Math.max(0,now-Date.parse(e.lastTriggeredAt))/86400000;const recency=Math.exp(-.03*days),frequency=1-Math.exp(-e.triggerCount/5),protection=e.tier==="pinned"?1:e.tier==="stable"?.5:0;return .45*relevance+.2*frequency+.15*recency+.15*e.confidence+.05*protection;}
function tokenize(v:string){return [...new Set(v.toLowerCase().split(/[^\p{L}\p{N}_.-]+/u).filter(Boolean))];}
function unique(v:readonly string[]){return [...new Set(v.map(x=>x.trim().toLowerCase()).filter(Boolean))];}
function clamp(v:number){if(!Number.isFinite(v))throw new TypeError("confidence must be finite");return Math.min(1,Math.max(0,v));}
function validate(v:KnowledgeInput){if(!v.id.trim()||!v.title.trim()||!v.truth.trim()||!v.action.trim())throw new Error("id, title, truth and action are required");}
