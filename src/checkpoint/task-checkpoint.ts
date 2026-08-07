export interface TaskRollbackPoint { readonly id: string; readonly taskId: string; readonly createdAt: string; readonly metadata?: Readonly<Record<string, string>>; }
export interface TaskRollbackPort {
  create(taskId: string, metadata?: Readonly<Record<string, string>>): Promise<TaskRollbackPoint>;
  rollback(checkpoint: TaskRollbackPoint): Promise<void>;
  discard(checkpoint: TaskRollbackPoint): Promise<void>;
}
export type TaskRollbackState = "idle" | "creating" | "active" | "rolling_back" | "rolled_back" | "committing" | "committed" | "failed";
export interface TaskRollbackSnapshot { readonly taskId: string; readonly state: TaskRollbackState; readonly checkpoint?: TaskRollbackPoint; readonly error?: string; }

/** Task-scoped checkpoint lifecycle. All effects are delegated to a host port. */
export class TaskRollbackMachine {
  private snapshotValue: TaskRollbackSnapshot;
  constructor(private readonly taskId: string, private readonly port: TaskRollbackPort) { this.snapshotValue = { taskId, state: "idle" }; }
  get snapshot(): TaskRollbackSnapshot { return this.snapshotValue; }
  async begin(metadata?: Readonly<Record<string, string>>): Promise<TaskRollbackSnapshot> {
    this.expect("idle"); this.snapshotValue = { taskId: this.taskId, state: "creating" };
    try { const checkpoint = await this.port.create(this.taskId, metadata); return this.snapshotValue = { taskId: this.taskId, state: "active", checkpoint }; }
    catch (error) { this.fail(error); throw error; }
  }
  async rollback(): Promise<TaskRollbackSnapshot> {
    this.expect("active"); const checkpoint = this.snapshotValue.checkpoint!; this.snapshotValue = { taskId: this.taskId, state: "rolling_back", checkpoint };
    try { await this.port.rollback(checkpoint); return this.snapshotValue = { taskId: this.taskId, state: "rolled_back", checkpoint }; }
    catch (error) { this.fail(error, checkpoint); throw error; }
  }
  async commit(): Promise<TaskRollbackSnapshot> {
    this.expect("active"); const checkpoint = this.snapshotValue.checkpoint!; this.snapshotValue = { taskId: this.taskId, state: "committing", checkpoint };
    try { await this.port.discard(checkpoint); return this.snapshotValue = { taskId: this.taskId, state: "committed", checkpoint }; }
    catch (error) { this.fail(error, checkpoint); throw error; }
  }
  private expect(state: TaskRollbackState): void { if (this.snapshotValue.state !== state) throw new Error(`Invalid checkpoint transition: ${this.snapshotValue.state} -> expected ${state}`); }
  private fail(error: unknown, checkpoint?: TaskRollbackPoint): void { this.snapshotValue = { taskId: this.taskId, state: "failed", ...(checkpoint ? { checkpoint } : {}), error: error instanceof Error ? error.message : String(error) }; }
}
