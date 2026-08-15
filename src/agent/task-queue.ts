export type AgentTaskStatus = "queued" | "running" | "succeeded" | "failed" | "exhausted";

export interface AgentTask<TOutput = unknown> {
  readonly id: string;
  readonly run: (context: AgentTaskRunContext) => Promise<TOutput>;
}

export interface AgentTaskRunContext {
  readonly attempt: number;
  readonly wave: number;
  readonly slot: number;
  readonly signal?: AbortSignal;
}

export interface AgentTaskCheckpoint<TOutput = unknown> {
  readonly id: string;
  readonly status: AgentTaskStatus;
  readonly attempts: number;
  readonly wave: number;
  readonly slot: number;
  readonly output?: TOutput;
  readonly error?: string;
  readonly updatedAt: string;
}

export interface AgentTaskQueueCheckpoint<TOutput = unknown> {
  readonly schemaVersion: 1;
  readonly tasks: readonly AgentTaskCheckpoint<TOutput>[];
}

export interface AgentTaskQueueLogger {
  readonly log: (line: string) => void;
}

export interface AgentTaskQueueOptions<TOutput = unknown> {
  readonly concurrency?: number;
  readonly maxRetries?: number;
  readonly checkpoint?: AgentTaskQueueCheckpoint<TOutput>;
  readonly logger?: AgentTaskQueueLogger;
  readonly now?: () => Date;
  readonly signal?: AbortSignal;
}

export interface AgentTaskProgress {
  readonly total: number;
  readonly queued: number;
  readonly running: number;
  readonly succeeded: number;
  readonly failed: number;
  readonly exhausted: number;
  readonly completed: number;
  readonly activeWave: number;
  readonly activeSlots: number;
}

export interface AgentTaskQueueResult<TOutput = unknown> {
  readonly checkpoint: AgentTaskQueueCheckpoint<TOutput>;
  readonly progress: AgentTaskProgress;
}

interface MutableTaskState<TOutput> {
  id: string;
  status: AgentTaskStatus;
  attempts: number;
  wave: number;
  slot: number;
  output?: TOutput;
  error?: string;
  updatedAt: string;
}

const DEFAULT_CONCURRENCY = 4;

export class AgentTaskQueue<TOutput = unknown> {
  private readonly tasks: readonly AgentTask<TOutput>[];
  private readonly states = new Map<string, MutableTaskState<TOutput>>();
  private readonly concurrency: number;
  private readonly maxRetries: number;
  private readonly logger: AgentTaskQueueLogger | undefined;
  private readonly now: () => Date;
  private readonly signal: AbortSignal | undefined;
  private activeWave = 0;

  constructor(tasks: readonly AgentTask<TOutput>[], options: AgentTaskQueueOptions<TOutput> = {}) {
    this.tasks = tasks;
    this.concurrency = positiveInteger(options.concurrency, DEFAULT_CONCURRENCY, "concurrency");
    this.maxRetries = nonNegativeInteger(options.maxRetries, 0, "maxRetries");
    this.logger = options.logger;
    this.now = options.now ?? (() => new Date());
    this.signal = options.signal;
    const ids = new Set<string>();
    for (const task of tasks) {
      if (ids.has(task.id)) throw new Error(`Duplicate task id: ${task.id}`);
      ids.add(task.id);
      this.states.set(task.id, this.restoreState(task.id, options.checkpoint));
    }
  }

  get progress(): AgentTaskProgress {
    return summarize([...this.states.values()], this.activeWave, this.concurrency);
  }

  get checkpoint(): AgentTaskQueueCheckpoint<TOutput> {
    return {
      schemaVersion: 1,
      tasks: this.tasks.map((task) => freezeState(this.requireState(task.id))),
    };
  }

  async run(): Promise<AgentTaskQueueResult<TOutput>> {
    this.log("queue:start", { total: this.tasks.length, concurrency: this.concurrency, maxRetries: this.maxRetries });
    while (true) {
      if (this.signal?.aborted) throw new Error("Task queue aborted");
      const batch = this.nextBatch();
      if (!batch.length) break;
      this.activeWave += 1;
      this.log("wave:start", { wave: this.activeWave, size: batch.length, progress: this.progress });
      await Promise.all(batch.map((task, index) => this.runTask(task, index + 1)));
      this.log("wave:finish", { wave: this.activeWave, progress: this.progress });
    }
    const progress = this.progress;
    this.log("queue:finish", { progress });
    return { checkpoint: this.checkpoint, progress };
  }

  private nextBatch(): readonly AgentTask<TOutput>[] {
    return this.tasks
      .filter((task) => this.requireState(task.id).status === "queued")
      .slice(0, this.concurrency);
  }

  private async runTask(task: AgentTask<TOutput>, slot: number): Promise<void> {
    const state = this.requireState(task.id);
    state.status = "running";
    state.wave = this.activeWave;
    state.slot = slot;
    state.attempts += 1;
    delete state.error;
    state.updatedAt = this.timestamp();
    this.log("task:start", { id: task.id, attempt: state.attempts, wave: state.wave, slot });
    try {
      const context: AgentTaskRunContext = this.signal
        ? { attempt: state.attempts, wave: state.wave, slot, signal: this.signal }
        : { attempt: state.attempts, wave: state.wave, slot };
      const output = await task.run(context);
      state.status = "succeeded";
      state.output = output;
      state.updatedAt = this.timestamp();
      this.log("task:succeeded", { id: task.id, attempt: state.attempts, wave: state.wave, slot });
    } catch (error) {
      state.error = errorMessage(error);
      state.updatedAt = this.timestamp();
      if (state.attempts <= this.maxRetries) {
        state.status = "queued";
        this.log("task:retry", { id: task.id, attempt: state.attempts, maxRetries: this.maxRetries, error: state.error });
        return;
      }
      state.status = "exhausted";
      this.log("task:exhausted", { id: task.id, attempt: state.attempts, error: state.error });
    }
  }

  private restoreState(id: string, checkpoint: AgentTaskQueueCheckpoint<TOutput> | undefined): MutableTaskState<TOutput> {
    const saved = checkpoint?.tasks.find((task) => task.id === id);
    if (!saved) return this.newState(id);
    if (saved.status === "succeeded" || saved.status === "exhausted") return { ...saved };
    return { ...saved, status: "queued", slot: 0, updatedAt: this.timestamp() };
  }

  private newState(id: string): MutableTaskState<TOutput> {
    return { id, status: "queued", attempts: 0, wave: 0, slot: 0, updatedAt: this.timestamp() };
  }

  private requireState(id: string): MutableTaskState<TOutput> {
    const state = this.states.get(id);
    if (!state) throw new Error(`Missing task state: ${id}`);
    return state;
  }

  private timestamp(): string {
    return this.now().toISOString();
  }

  private log(event: string, fields: Readonly<Record<string, unknown>>): void {
    this.logger?.log(JSON.stringify({ event, ...fields }));
  }
}

function summarize<TOutput>(states: readonly MutableTaskState<TOutput>[], activeWave: number, concurrency: number): AgentTaskProgress {
  const count = (status: AgentTaskStatus) => states.filter((state) => state.status === status).length;
  const succeeded = count("succeeded");
  const exhausted = count("exhausted");
  return {
    total: states.length,
    queued: count("queued"),
    running: count("running"),
    succeeded,
    failed: exhausted,
    exhausted,
    completed: succeeded + exhausted,
    activeWave,
    activeSlots: Math.min(concurrency, states.filter((state) => state.status === "queued" || state.status === "running").length),
  };
}

function freezeState<TOutput>(state: MutableTaskState<TOutput>): AgentTaskCheckpoint<TOutput> {
  return { ...state };
}

function positiveInteger(value: number | undefined, fallback: number, name: string): number {
  const result = value ?? fallback;
  if (!Number.isInteger(result) || result <= 0) throw new RangeError(`${name} must be a positive integer`);
  return result;
}

function nonNegativeInteger(value: number | undefined, fallback: number, name: string): number {
  const result = value ?? fallback;
  if (!Number.isInteger(result) || result < 0) throw new RangeError(`${name} must be a non-negative integer`);
  return result;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
