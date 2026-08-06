export type KnowledgeTier = "pinned" | "stable" | "temporary";
export interface KnowledgeEntry { readonly id:string; readonly title:string; readonly truth:string; readonly action:string; readonly tags:readonly string[]; readonly tier:KnowledgeTier; readonly confidence:number; readonly createdAt:string; readonly lastTriggeredAt:string; readonly triggerCount:number; }
export interface KnowledgeInput { readonly id:string; readonly title:string; readonly truth:string; readonly action:string; readonly tags?:readonly string[]; readonly tier?:KnowledgeTier; readonly confidence?:number; }
export interface RankedKnowledge { readonly entry:KnowledgeEntry; readonly score:number; }
export interface HermesSnapshot { readonly schemaVersion:1; readonly entries:readonly KnowledgeEntry[]; }
