export type Capability =
  | "fs.read"
  | "fs.write"
  | "process.safe"
  | "process.dangerous"
  | "network.read"
  | "network.write"
  | "git.read"
  | "git.write"
  | "delete"
  | "publish";

export type RiskLevel = "read" | "sandboxed" | "review" | "dangerous" | "external";

export interface ToolRequest<TInput = unknown> {
  readonly id: string;
  readonly tool: string;
  readonly input: TInput;
  readonly requiredCapabilities: readonly Capability[];
  readonly risk: RiskLevel;
}

export interface ToolResult<TOutput = unknown> {
  readonly requestId: string;
  readonly ok: boolean;
  readonly output?: TOutput;
  readonly error?: string;
  readonly durationMs: number;
}

export interface TaskCheckpoint {
  readonly schemaVersion: 1;
  readonly taskId: string;
  readonly status: "planning" | "running" | "waiting_user" | "testing" | "done" | "failed";
  readonly currentStep: number;
  readonly completedSteps: readonly string[];
  readonly pendingStep?: string;
  readonly changedPaths: readonly string[];
  readonly toolCallCount: number;
  readonly tokenBudgetRemaining: number;
  readonly updatedAt: string;
}
