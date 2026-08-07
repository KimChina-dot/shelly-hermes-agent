import type {
  ChatCompletion,
  ChatCompletionRequest,
  ChatMessage,
  ChatModelPort,
  ChatToolCall,
} from "../agent/types.js";

export interface OpenAICompatibleOptions {
  readonly baseUrl: string;
  readonly apiKey: string;
  readonly model: string;
  readonly timeoutMs?: number;
  readonly fetch?: typeof globalThis.fetch;
  readonly headers?: Readonly<Record<string, string>>;
}

/** Minimal OpenAI-compatible Chat Completions adapter with no vendor SDK dependency. */
export class OpenAICompatibleChatModel implements ChatModelPort {
  private readonly baseUrl: string;
  private readonly timeoutMs: number;
  private readonly fetchImpl: typeof globalThis.fetch;

  constructor(private readonly options: OpenAICompatibleOptions) {
    this.baseUrl = options.baseUrl.replace(/\/+$/, "");
    if (!this.baseUrl) throw new TypeError("baseUrl is required");
    if (!options.apiKey) throw new TypeError("apiKey is required");
    if (!options.model) throw new TypeError("model is required");
    this.timeoutMs = options.timeoutMs ?? 120_000;
    this.fetchImpl = options.fetch ?? globalThis.fetch;
  }

  async complete(request: ChatCompletionRequest): Promise<ChatCompletion> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    const onAbort = () => controller.abort();
    request.signal?.addEventListener("abort", onAbort, { once: true });
    try {
      const response = await this.fetchImpl(`${this.baseUrl}/chat/completions`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${this.options.apiKey}`,
          ...this.options.headers,
        },
        body: JSON.stringify({
          model: this.options.model,
          messages: request.messages.map(toWireMessage),
          ...(request.tools?.length
            ? {
                tools: request.tools.map((tool) => ({
                  type: "function",
                  function: {
                    name: tool.name,
                    description: tool.description,
                    parameters: tool.inputSchema,
                  },
                })),
                tool_choice: "auto",
              }
            : {}),
        }),
        signal: controller.signal,
      });
      if (!response.ok) {
        const body = (await response.text()).slice(0, 2_000);
        throw new Error(`Model request failed (${response.status}): ${body}`);
      }
      const data = await response.json() as WireResponse;
      const wire = data.choices?.[0]?.message;
      if (!wire) throw new Error("Model response does not contain a message");
      const message: ChatMessage = {
        role: "assistant",
        content: wire.content ?? "",
        ...(wire.tool_calls?.length
          ? { toolCalls: wire.tool_calls.map(fromWireToolCall) }
          : {}),
      };
      const usage = data.usage
        ? {
            inputTokens: data.usage.prompt_tokens ?? 0,
            outputTokens: data.usage.completion_tokens ?? 0,
          }
        : undefined;
      return { message, ...(usage ? { usage } : {}) };
    } finally {
      clearTimeout(timer);
      request.signal?.removeEventListener("abort", onAbort);
    }
  }
}

function toWireMessage(message: ChatMessage): Record<string, unknown> {
  if (message.role === "tool") {
    return { role: "tool", content: message.content, tool_call_id: message.toolCallId };
  }
  if (message.role === "assistant" && message.toolCalls?.length) {
    return {
      role: "assistant",
      content: message.content || null,
      tool_calls: message.toolCalls.map((call) => ({
        id: call.id,
        type: "function",
        function: { name: call.name, arguments: call.arguments },
      })),
    };
  }
  return { role: message.role, content: message.content };
}

function fromWireToolCall(call: WireToolCall): ChatToolCall {
  if (!call.id || !call.function?.name) throw new Error("Invalid tool call in model response");
  return {
    id: call.id,
    name: call.function.name,
    arguments: call.function.arguments ?? "{}",
  };
}

interface WireToolCall {
  id?: string;
  function?: { name?: string; arguments?: string };
}

interface WireResponse {
  choices?: Array<{ message?: { content?: string | null; tool_calls?: WireToolCall[] } }>;
  usage?: { prompt_tokens?: number; completion_tokens?: number };
}
