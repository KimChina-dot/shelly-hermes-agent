export interface ContextItem {
  readonly id: string;
  readonly content: string;
  readonly priority?: number;
}

export interface ContextRequest {
  readonly prompt: string;
  readonly history: readonly { readonly role: string; readonly content: string }[];
  readonly characterBudget?: number;
  readonly tokenBudget?: number;
}

/** Optional, platform-neutral source of automatically recalled context. */
export interface ContextProviderPort {
  provide(request: ContextRequest): Promise<readonly ContextItem[]>;
}

export interface SummaryPort {
  summarize(text: string, budget: ContextBudget): Promise<string>;
}

export interface TokenCounterPort {
  count(text: string): number;
}

export interface ContextBudget {
  readonly maxCharacters?: number;
  readonly maxTokens?: number;
}

export interface CompressedContext {
  readonly text: string;
  readonly characters: number;
  readonly tokens: number;
  readonly truncated: boolean;
}

const defaultCounter: TokenCounterPort = { count: (text) => Math.ceil(text.length / 4) };

/** Deterministic ordering and clipping. A summarizer is optional; clipping is always the final guard. */
export async function compressContext(
  items: readonly ContextItem[],
  budget: ContextBudget,
  summary?: SummaryPort,
  counter: TokenCounterPort = defaultCounter,
): Promise<CompressedContext> {
  const maxCharacters = limit(budget.maxCharacters, Number.MAX_SAFE_INTEGER, "maxCharacters");
  const maxTokens = limit(budget.maxTokens, Number.MAX_SAFE_INTEGER, "maxTokens");
  const ordered = items.map((item, index) => ({ item, index })).sort((a, b) =>
    (b.item.priority ?? 0) - (a.item.priority ?? 0) || a.item.id.localeCompare(b.item.id) || a.index - b.index,
  );
  let source = ordered.map(({ item }) => `[${item.id}]\n${item.content.trim()}`).filter(Boolean).join("\n\n");
  const initiallyFits = fits(source, maxCharacters, maxTokens, counter);
  if (!initiallyFits && summary) source = await summary.summarize(source, budget);
  let output = source.slice(0, maxCharacters);
  while (output && counter.count(output) > maxTokens) output = output.slice(0, output.length - 1);
  return { text: output, characters: output.length, tokens: counter.count(output), truncated: !initiallyFits || output !== source };
}

function fits(text: string, chars: number, tokens: number, counter: TokenCounterPort): boolean {
  return text.length <= chars && counter.count(text) <= tokens;
}
function limit(value: number | undefined, fallback: number, name: string): number {
  const result = value ?? fallback;
  if (!Number.isInteger(result) || result < 0) throw new RangeError(`${name} must be a non-negative integer`);
  return result;
}
