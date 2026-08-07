import { compressContext } from "../context/index.js";
import type {
  AgentRunOptions,
  AgentRunResult,
  AgentTool,
  ChatMessage,
  ChatModelPort,
  ChatUsage,
} from "./types.js";

export class AgentLimitError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AgentLimitError";
  }
}

export class CodingAgent {
  private readonly tools = new Map<string, AgentTool>();

  constructor(private readonly model: ChatModelPort, tools: readonly AgentTool[]) {
    for (const tool of tools) {
      const name = tool.definition.name.trim();
      if (!name) throw new TypeError("Tool name must not be empty");
      if (this.tools.has(name)) throw new TypeError(`Duplicate tool '${name}'`);
      this.tools.set(name, tool);
    }
  }

  async run(prompt: string, options: AgentRunOptions): Promise<AgentRunResult> {
    const maxTurns = positive(options.maxTurns, 12, "maxTurns");
    const maxToolCalls = nonNegative(options.maxToolCalls, 24, "maxToolCalls");
    const confirm = options.confirm ?? (async () => false);
    const history = options.history ?? [];
    const recalled = options.contextProvider
      ? await options.contextProvider.provide({
          prompt,
          history,
          ...(options.contextCharacterBudget === undefined ? {} : { characterBudget: options.contextCharacterBudget }),
          ...(options.contextTokenBudget === undefined ? {} : { tokenBudget: options.contextTokenBudget }),
        })
      : [];
    const compressed = recalled.length
      ? await compressContext(recalled, {
          ...(options.contextCharacterBudget === undefined ? {} : { maxCharacters: options.contextCharacterBudget }),
          ...(options.contextTokenBudget === undefined ? {} : { maxTokens: options.contextTokenBudget }),
        }, options.contextSummary, options.contextTokenCounter)
      : undefined;
    const messages: ChatMessage[] = [
      { role: "system", content: options.systemPrompt },
      ...(compressed?.text ? [{ role: "system" as const, content: `Recalled context:\n${compressed.text}` }] : []),
      ...history,
      { role: "user", content: prompt },
    ];
    const usage = { inputTokens: 0, outputTokens: 0 };
    let toolCalls = 0;

    for (let turn = 1; turn <= maxTurns; turn += 1) {
      options.onEvent?.({ type: "model_start", turn });
      const completion = await this.model.complete({
        messages,
        tools: Array.from(this.tools.values(), (tool) => tool.definition),
        ...(options.signal ? { signal: options.signal } : {}),
      });
      addUsage(usage, completion.usage);
      messages.push(completion.message);
      const calls = completion.message.toolCalls ?? [];
      if (calls.length === 0) {
        return {
          answer: completion.message.content,
          messages,
          turns: turn,
          toolCalls,
          usage,
        };
      }

      for (const call of calls) {
        toolCalls += 1;
        if (toolCalls > maxToolCalls) {
          throw new AgentLimitError(`Tool-call limit exceeded (${maxToolCalls})`);
        }
        options.onEvent?.({ type: "tool_start", name: call.name, id: call.id });
        const tool = this.tools.get(call.name);
        let output: unknown;
        let ok = false;
        try {
          if (!tool) throw new Error(`Unknown tool '${call.name}'`);
          const input = parseArguments(call.arguments);
          output = await tool.execute(input, {
            confirm,
            ...(options.signal ? { signal: options.signal } : {}),
          });
          ok = true;
        } catch (error) {
          output = { error: errorMessage(error) };
        }
        options.onEvent?.({ type: "tool_finish", name: call.name, id: call.id, ok });
        messages.push({
          role: "tool",
          name: call.name,
          toolCallId: call.id,
          content: serializeToolOutput(output),
        });
      }
    }
    throw new AgentLimitError(`Turn limit exceeded (${maxTurns})`);
  }
}

function positive(value: number | undefined, fallback: number, name: string): number {
  const result = value ?? fallback;
  if (!Number.isInteger(result) || result <= 0) throw new RangeError(`${name} must be a positive integer`);
  return result;
}

function nonNegative(value: number | undefined, fallback: number, name: string): number {
  const result = value ?? fallback;
  if (!Number.isInteger(result) || result < 0) throw new RangeError(`${name} must be a non-negative integer`);
  return result;
}

function parseArguments(value: string): unknown {
  if (!value.trim()) return {};
  try {
    return JSON.parse(value) as unknown;
  } catch {
    throw new Error("Tool arguments are not valid JSON");
  }
}

function serializeToolOutput(value: unknown): string {
  const serialized = JSON.stringify(value ?? null);
  return serialized.length <= 100_000
    ? serialized
    : `${serialized.slice(0, 100_000)}\n[output truncated]`;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

interface MutableUsage {
  inputTokens: number;
  outputTokens: number;
}

function addUsage(total: MutableUsage, usage: ChatUsage | undefined): void {
  if (!usage) return;
  total.inputTokens += usage.inputTokens;
  total.outputTokens += usage.outputTokens;
}
