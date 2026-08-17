import type { TextStorePort } from "../core/ports.js";
import type { ChatMessage, ChatToolCall, ChatUsage } from "../agent/types.js";

export type SessionEvent =
  | { readonly type: "turn_start"; readonly prompt: string }
  | { readonly type: "turn_end"; readonly reason: "completed" | "cancelled" | "failed" | "limit" }
  | { readonly type: "step_start"; readonly turn: number }
  | { readonly type: "step_end"; readonly turn: number; readonly usage?: ChatUsage }
  | { readonly type: "context_message"; readonly message: ChatMessage }
  | { readonly type: "user_message"; readonly message: ChatMessage }
  | { readonly type: "assistant_message"; readonly message: ChatMessage }
  | { readonly type: "tool_call"; readonly call: ChatToolCall }
  | { readonly type: "tool_result"; readonly message: ChatMessage };

export interface SessionEventEnvelope {
  readonly schemaVersion: 1;
  readonly sessionId: string;
  readonly sequence: number;
  readonly timestamp: string;
  readonly event: SessionEvent;
}

export interface SessionEventLogOptions {
  readonly store?: TextStorePort;
  readonly path?: string;
  readonly now?: () => Date;
  readonly initialEvents?: readonly SessionEventEnvelope[];
}

/** Append-only session facts used for replay, model-history projection, and forks. */
export class SessionEventLog {
  private readonly records: SessionEventEnvelope[];
  private readonly store: TextStorePort | undefined;
  private readonly path: string;
  private readonly now: () => Date;
  private writeTail: Promise<void> = Promise.resolve();

  constructor(readonly sessionId: string, options: SessionEventLogOptions = {}) {
    if (!sessionId.trim()) throw new TypeError("sessionId must not be empty");
    this.store = options.store;
    this.path = options.path ?? `.luma/sessions/${sessionId}.jsonl`;
    this.now = options.now ?? (() => new Date());
    this.records = validateInitialEvents(sessionId, options.initialEvents ?? []);
  }

  static async load(sessionId: string, options: Omit<SessionEventLogOptions, "initialEvents">): Promise<SessionEventLog> {
    const path = options.path ?? `.luma/sessions/${sessionId}.jsonl`;
    const content = await options.store?.read(path);
    const records = content ? parseJsonLines(content) : [];
    return new SessionEventLog(sessionId, { ...options, path, initialEvents: records });
  }

  get size(): number {
    return this.records.length;
  }

  get lastSequence(): number {
    return this.records.at(-1)?.sequence ?? 0;
  }

  append(event: SessionEvent): Promise<SessionEventEnvelope> {
    const operation = this.writeTail.then(async () => {
      const envelope: SessionEventEnvelope = {
        schemaVersion: 1,
        sessionId: this.sessionId,
        sequence: this.lastSequence + 1,
        timestamp: this.now().toISOString(),
        event: clone(event),
      };
      await this.store?.append(this.path, `${JSON.stringify(envelope)}\n`);
      this.records.push(envelope);
      return envelope;
    });
    this.writeTail = operation.then(() => undefined, () => undefined);
    return operation;
  }

  replay(afterSequence = 0, throughSequence = this.lastSequence): readonly SessionEventEnvelope[] {
    validateBoundary(afterSequence, "afterSequence");
    validateBoundary(throughSequence, "throughSequence");
    if (afterSequence > throughSequence) throw new RangeError("afterSequence must not exceed throughSequence");
    return this.records
      .filter((record) => record.sequence > afterSequence && record.sequence <= throughSequence)
      .map(clone);
  }

  deriveMessages(throughSequence = this.lastSequence): readonly ChatMessage[] {
    return this.replay(0, throughSequence).flatMap(({ event }) => {
      switch (event.type) {
        case "context_message":
        case "user_message":
        case "assistant_message":
        case "tool_result":
          return [clone(event.message)];
        default:
          return [];
      }
    });
  }

  async fork(newSessionId: string, throughSequence = this.lastSequence, options: SessionEventLogOptions = {}): Promise<SessionEventLog> {
    validateBoundary(throughSequence, "throughSequence");
    if (throughSequence > this.lastSequence) throw new RangeError("Fork boundary exceeds the session log");
    const fork = new SessionEventLog(newSessionId, options);
    for (const record of this.replay(0, throughSequence)) await fork.append(record.event);
    return fork;
  }
}

function parseJsonLines(content: string): SessionEventEnvelope[] {
  return content.split(/\r?\n/).filter(Boolean).map((line, index) => {
    let value: unknown;
    try {
      value = JSON.parse(line);
    } catch (error) {
      throw new SessionEventLogError(`Invalid session event JSON at line ${index + 1}`, { cause: error });
    }
    return value as SessionEventEnvelope;
  });
}

function validateInitialEvents(sessionId: string, events: readonly SessionEventEnvelope[]): SessionEventEnvelope[] {
  return events.map((record, index) => {
    const expected = index + 1;
    if (record.schemaVersion !== 1 || record.sessionId !== sessionId || record.sequence !== expected) {
      throw new SessionEventLogError(`Invalid session event at sequence ${expected}`);
    }
    if (!Number.isFinite(Date.parse(record.timestamp)) || !record.event || typeof record.event.type !== "string") {
      throw new SessionEventLogError(`Invalid session event payload at sequence ${expected}`);
    }
    return clone(record);
  });
}

function validateBoundary(value: number, name: string): void {
  if (!Number.isInteger(value) || value < 0) throw new RangeError(`${name} must be a non-negative integer`);
}

function clone<T>(value: T): T {
  return structuredClone(value);
}

export class SessionEventLogError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
    this.name = "SessionEventLogError";
  }
}
