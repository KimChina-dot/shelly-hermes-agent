export type ChatRole = "system" | "user" | "assistant" | "tool";

export interface ChatToolCall {
  readonly id: string;
  readonly name: string;
  readonly arguments: string;
}

export interface ChatMessage {
  readonly role: ChatRole;
  readonly content: string;
  readonly name?: string;
  readonly toolCallId?: string;
  readonly toolCalls?: readonly ChatToolCall[];
}

export interface ChatToolDefinition {
  readonly name: string;
  readonly description: string;
  readonly inputSchema: Readonly<Record<string, unknown>>;
}

export interface ChatUsage {
  readonly inputTokens: number;
  readonly outputTokens: number;
}

export interface ChatCompletionRequest {
  readonly messages: readonly ChatMessage[];
  readonly tools?: readonly ChatToolDefinition[];
  readonly signal?: AbortSignal;
}

export interface ChatCompletion {
  readonly message: ChatMessage;
  readonly usage?: ChatUsage;
}

/** Cross-platform model boundary. Android and Windows may provide different transports. */
export interface ChatModelPort {
  complete(request: ChatCompletionRequest): Promise<ChatCompletion>;
}

export interface AgentToolContext {
  readonly signal?: AbortSignal;
  readonly confirm: (question: string) => Promise<boolean>;
}

export interface AgentTool {
  readonly definition: ChatToolDefinition;
  execute(input: unknown, context: AgentToolContext): Promise<unknown>;
}

export interface AgentRunOptions {
  readonly systemPrompt: string;
  readonly history?: readonly ChatMessage[];
  readonly contextProvider?: import("../context/index.js").ContextProviderPort;
  readonly contextSummary?: import("../context/index.js").SummaryPort;
  readonly contextTokenCounter?: import("../context/index.js").TokenCounterPort;
  readonly contextCharacterBudget?: number;
  readonly contextTokenBudget?: number;
  readonly maxTurns?: number;
  readonly maxToolCalls?: number;
  readonly signal?: AbortSignal;
  readonly confirm?: (question: string) => Promise<boolean>;
  readonly onEvent?: (event: AgentEvent) => void;
}

export type AgentEvent =
  | { readonly type: "model_start"; readonly turn: number }
  | { readonly type: "tool_start"; readonly name: string; readonly id: string }
  | { readonly type: "tool_finish"; readonly name: string; readonly id: string; readonly ok: boolean };

export interface AgentRunResult {
  readonly answer: string;
  readonly messages: readonly ChatMessage[];
  readonly turns: number;
  readonly toolCalls: number;
  readonly usage: ChatUsage;
}
