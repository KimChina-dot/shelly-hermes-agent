import type { ContextItem, ContextProviderPort, ContextRequest } from "../context/index.js";
import type { HermesMemorySystem } from "./memory-system.js";
import type { RankedKnowledge } from "./types.js";

export interface HermesRecallRequest { readonly query: string; readonly limit?: number; readonly touch?: boolean; }
export interface HermesRecallResult { readonly items: readonly RankedKnowledge[]; readonly context: readonly ContextItem[]; }

/** Automatic recall API with optional trigger accounting. */
export async function recallHermes(memory: HermesMemorySystem, request: HermesRecallRequest): Promise<HermesRecallResult> {
  const items = memory.retrieve(request.query, request.limit ?? 5);
  if (request.touch) for (const item of items) await memory.touch(item.entry.id);
  return { items, context: items.map(({ entry, score }) => ({ id: entry.id, priority: score, content: `${entry.title}\nTruth: ${entry.truth}\nAction: ${entry.action}` })) };
}

export class HermesContextProvider implements ContextProviderPort {
  constructor(private readonly memory: HermesMemorySystem, private readonly limit = 5, private readonly touch = false) {}
  async provide(request: ContextRequest): Promise<readonly ContextItem[]> {
    return (await recallHermes(this.memory, { query: request.prompt, limit: this.limit, touch: this.touch })).context;
  }
}
