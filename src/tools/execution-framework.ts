import type { AgentTool, AgentToolContext, ChatToolDefinition } from "../agent/types.js";
import type { ClockPort, TextStorePort } from "../core/ports.js";
import type { Capability, RiskLevel, ToolRequest } from "../core/types.js";
import type { PolicyDecision, PolicyEngine } from "../policy/policy-engine.js";

export interface ToolMetadata {
  readonly capabilities: readonly Capability[];
  readonly risk: RiskLevel;
  readonly mutatesWorkspace?: boolean;
  readonly checkpoint?: "required" | "best_effort" | "none";
  readonly maxResultChars?: number;
}

export interface PatchPreview {
  readonly summary: string;
  readonly patch?: string;
  readonly truncated?: boolean;
}

export interface ExecutionTool {
  readonly definition: ChatToolDefinition;
  readonly metadata: ToolMetadata;
  preview?(input: unknown, signal?: AbortSignal): Promise<PatchPreview | undefined>;
  execute(input: unknown, context: { readonly signal?: AbortSignal }): Promise<unknown>;
}

export interface ApprovalRequest {
  readonly request: ToolRequest;
  readonly decision: PolicyDecision;
  readonly preview?: PatchPreview;
  readonly message: string;
}

export interface ApprovalPort {
  approve(request: ApprovalRequest): Promise<boolean>;
}

export type AuditPhase = "requested" | "policy" | "approval" | "checkpoint" | "started" | "finished" | "rollback";
export interface AuditEvent {
  readonly schemaVersion: 1;
  readonly timestamp: string;
  readonly phase: AuditPhase;
  readonly requestId: string;
  readonly tool: string;
  readonly risk: RiskLevel;
  readonly capabilities: readonly Capability[];
  readonly details?: Readonly<Record<string, unknown>>;
}
export interface AuditSink { append(event: AuditEvent): Promise<void>; }

export interface GitCheckpoint { readonly id: string; readonly revision: string; readonly snapshotRevision?: string; }
export interface GitCheckpointPort {
  create(requestId: string): Promise<GitCheckpoint>;
  diff(checkpoint: GitCheckpoint, maxChars: number): Promise<PatchPreview>;
  rollback(checkpoint: GitCheckpoint): Promise<void>;
}

export interface ExecutionFrameworkOptions {
  readonly policy: PolicyEngine;
  readonly approval: ApprovalPort;
  readonly audit: AuditSink;
  readonly clock: ClockPort;
  readonly checkpoints?: GitCheckpointPort;
  readonly defaultMaxResultChars?: number;
  readonly rollbackOnFailure?: boolean;
}

export interface ExecutionResult {
  readonly requestId: string;
  readonly ok: boolean;
  readonly output?: unknown;
  readonly error?: string;
  readonly durationMs: number;
  readonly truncated: boolean;
  readonly originalChars?: number;
  readonly checkpoint?: GitCheckpoint;
  readonly patch?: PatchPreview;
}

/** Single, platform-neutral choke point for every model-visible tool invocation. */
export class ToolExecutionFramework {
  private readonly tools = new Map<string, ExecutionTool>();
  private sequence = 0;

  constructor(private readonly options: ExecutionFrameworkOptions) {}

  register(tool: ExecutionTool): void {
    const name = tool.definition.name.trim();
    if (!name || name !== tool.definition.name) throw new TypeError("Tool name must be non-empty and trimmed");
    if (this.tools.has(name)) throw new TypeError(`Duplicate tool '${name}'`);
    if (!Array.isArray(tool.metadata.capabilities)) throw new TypeError(`Tool '${name}' has invalid capabilities`);
    this.tools.set(name, tool);
  }

  registerAll(tools: readonly ExecutionTool[]): void { for (const tool of tools) this.register(tool); }
  unregister(name: string): boolean { return this.tools.delete(name); }
  list(): readonly ExecutionTool[] { return [...this.tools.values()]; }
  definitions(): readonly ChatToolDefinition[] { return this.list().map(tool => tool.definition); }

  asAgentTools(): readonly AgentTool[] {
    return this.list().map(tool => ({
      definition: tool.definition,
      execute: (input: unknown, context: AgentToolContext) => this.execute(tool.definition.name, input, context),
    }));
  }

  async execute(name: string, input: unknown, context: AgentToolContext = { confirm: async () => false }): Promise<ExecutionResult> {
    const tool = this.tools.get(name);
    if (!tool) return this.failure(this.requestId(name), name, "Unknown tool", 0, false);
    const id = this.requestId(name);
    const started = this.options.clock.now().getTime();
    const request: ToolRequest = { id, tool: name, input, requiredCapabilities: tool.metadata.capabilities, risk: tool.metadata.risk };
    await this.audit("requested", request, { input: redact(input) });

    const decision = this.options.policy.evaluate(request);
    await this.audit("policy", request, { action: decision.action, reason: decision.reason, missingCapabilities: decision.missingCapabilities });
    if (decision.action === "deny") return this.failure(id, name, decision.reason, started, false, request);

    let preview: PatchPreview | undefined;
    try { preview = await tool.preview?.(input, context.signal); }
    catch (error) { return this.failure(id, name, `Preview failed: ${message(error)}`, started, false, request); }

    if (decision.action === "confirm") {
      const approvalRequest: ApprovalRequest = { request, decision, ...(preview ? { preview } : {}), message: approvalMessage(request, preview) };
      // Compatibility fallback lets existing CLI hosts keep their boolean confirm callback.
      const approved = await this.options.approval.approve(approvalRequest) || await context.confirm(approvalRequest.message);
      await this.audit("approval", request, { approved, preview: preview ? redact(preview) : undefined });
      if (!approved) return this.failure(id, name, "User denied tool execution", started, false, request);
    }

    let checkpoint: GitCheckpoint | undefined;
    const checkpointMode = tool.metadata.checkpoint ?? (tool.metadata.mutatesWorkspace ? "required" : "none");
    if (checkpointMode !== "none") {
      if (!this.options.checkpoints && checkpointMode === "required") return this.failure(id, name, "Git checkpoint service is required", started, false, request);
      try {
        checkpoint = await this.options.checkpoints?.create(id);
        await this.audit("checkpoint", request, { checkpoint });
      } catch (error) {
        if (checkpointMode === "required") return this.failure(id, name, `Checkpoint failed: ${message(error)}`, started, false, request);
        await this.audit("checkpoint", request, { warning: message(error) });
      }
    }

    await this.audit("started", request);
    try {
      const raw = await tool.execute(input, { ...(context.signal ? { signal: context.signal } : {}) });
      const limit = tool.metadata.maxResultChars ?? this.options.defaultMaxResultChars ?? 100_000;
      const limited = truncateResult(raw, limit);
      const patch = checkpoint && this.options.checkpoints ? await this.options.checkpoints.diff(checkpoint, limit) : undefined;
      const result: ExecutionResult = { requestId: id, ok: true, output: limited.value, durationMs: elapsed(started, this.options.clock), truncated: limited.truncated, ...(limited.originalChars ? { originalChars: limited.originalChars } : {}), ...(checkpoint ? { checkpoint } : {}), ...(patch ? { patch } : {}) };
      await this.audit("finished", request, { ok: true, durationMs: result.durationMs, truncated: result.truncated, patch: patch ? redact(patch) : undefined });
      return result;
    } catch (error) {
      let rollbackError: string | undefined;
      if (checkpoint && this.options.checkpoints && this.options.rollbackOnFailure !== false) {
        try { await this.options.checkpoints.rollback(checkpoint); await this.audit("rollback", request, { ok: true, checkpoint }); }
        catch (rollback) { rollbackError = message(rollback); await this.audit("rollback", request, { ok: false, error: rollbackError }); }
      }
      return this.failure(id, name, `${message(error)}${rollbackError ? `; rollback failed: ${rollbackError}` : ""}`, started, false, request, checkpoint);
    }
  }

  private requestId(name: string): string { return `${name}-${this.options.clock.now().getTime()}-${++this.sequence}`; }
  private async audit(phase: AuditPhase, request: ToolRequest, details?: Record<string, unknown>): Promise<void> {
    await this.options.audit.append({ schemaVersion: 1, timestamp: this.options.clock.now().toISOString(), phase, requestId: request.id, tool: request.tool, risk: request.risk, capabilities: request.requiredCapabilities, ...(details ? { details } : {}) });
  }
  private async failure(id: string, name: string, error: string, started: number, truncated: boolean, request?: ToolRequest, checkpoint?: GitCheckpoint): Promise<ExecutionResult> {
    const result: ExecutionResult = { requestId: id, ok: false, error, durationMs: started ? elapsed(started, this.options.clock) : 0, truncated, ...(checkpoint ? { checkpoint } : {}) };
    if (request) await this.audit("finished", request, { ok: false, error, durationMs: result.durationMs });
    return result;
  }
}

export class JsonlAuditSink implements AuditSink {
  constructor(private readonly store: TextStorePort, private readonly path = ".shelly/audit.jsonl") {}
  async append(event: AuditEvent): Promise<void> { await this.store.append(this.path, `${JSON.stringify(redact(event))}\n`); }
}

export class CallbackApproval implements ApprovalPort {
  constructor(private readonly callback: (request: ApprovalRequest) => boolean | Promise<boolean>) {}
  async approve(request: ApprovalRequest): Promise<boolean> { return this.callback(request); }
}

export class DenyApproval implements ApprovalPort { async approve(): Promise<boolean> { return false; } }

export function truncateResult(value: unknown, maxChars: number): { value: unknown; truncated: boolean; originalChars?: number } {
  if (!Number.isInteger(maxChars) || maxChars < 256) throw new RangeError("maxChars must be an integer >= 256");
  const serialized = safeJson(value);
  if (serialized.length <= maxChars) return { value, truncated: false };
  const head = Math.floor(maxChars * 0.7);
  const tail = Math.max(0, maxChars - head - 80);
  return { value: { truncated: true, originalChars: serialized.length, content: `${serialized.slice(0, head)}\n...[truncated]...\n${serialized.slice(-tail)}` }, truncated: true, originalChars: serialized.length };
}

function approvalMessage(request: ToolRequest, preview?: PatchPreview): string {
  return [`Approve ${request.tool} (${request.risk})?`, `Capabilities: ${request.requiredCapabilities.join(", ") || "none"}`, preview?.summary, preview?.patch].filter(Boolean).join("\n");
}
function elapsed(started: number, clock: ClockPort): number { return Math.max(0, clock.now().getTime() - started); }
function message(error: unknown): string { return error instanceof Error ? error.message : String(error); }
function safeJson(value: unknown): string { try { return JSON.stringify(value ?? null); } catch { return JSON.stringify({ error: "Result is not JSON-serializable" }); } }
function redact(value: unknown, key = ""): unknown {
  if (/token|secret|password|authorization|cookie|api[-_]?key/i.test(key)) return "[REDACTED]";
  if (Array.isArray(value)) return value.map(item => redact(item));
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value as Record<string, unknown>).map(([k, v]) => [k, redact(v, k)]));
  return value;
}
