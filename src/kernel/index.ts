export type KernelStatus =
  | "pending"
  | "running"
  | "completed"
  | "waiting_user"
  | "budget_exceeded"
  | "failed";

export interface KernelStep<Input = unknown> {
  id: string;
  input?: Input;
}

export interface KernelPlan {
  id: string;
  steps: readonly KernelStep[];
}

export interface StepResult<Output = unknown> {
  output?: Output;
  toolCalls?: number;
  tokens?: number;
  status?: "completed" | "waiting_user";
  waitingFor?: string;
}

export interface StepExecutionContext {
  planId: string;
  stepIndex: number;
  completedStepIds: readonly string[];
  usage: Readonly<KernelUsage>;
}

export interface StepExecutorPort {
  execute(step: KernelStep, context: StepExecutionContext): Promise<StepResult>;
}

export interface KernelCheckpointPort {
  load(key: string): Promise<KernelCheckpoint | null>;
  save(key: string, checkpoint: KernelCheckpoint): Promise<void>;
}

export interface KernelBudget {
  maxSteps?: number;
  maxToolCalls?: number;
  maxTokens?: number;
}

export interface KernelUsage {
  steps: number;
  toolCalls: number;
  tokens: number;
}

export interface KernelFailure {
  stepId: string | undefined;
  message: string;
}

export interface KernelCheckpoint {
  planId: string;
  status: KernelStatus;
  nextStep: number;
  completedStepIds: string[];
  outputs: Record<string, unknown>;
  usage: KernelUsage;
  currentStepId: string | undefined;
  waitingFor: string | undefined;
  failure: KernelFailure | undefined;
}

export interface MinimalKernelOptions {
  executor: StepExecutorPort;
  checkpoints: KernelCheckpointPort;
  budget?: KernelBudget;
}

/** A deterministic, resumable step runner with no dependency on a host OS. */
export class MinimalKernel {
  private readonly budget: Required<KernelBudget>;

  constructor(private readonly options: MinimalKernelOptions) {
    this.budget = {
      maxSteps: options.budget?.maxSteps ?? Number.POSITIVE_INFINITY,
      maxToolCalls: options.budget?.maxToolCalls ?? Number.POSITIVE_INFINITY,
      maxTokens: options.budget?.maxTokens ?? Number.POSITIVE_INFINITY,
    };
  }

  async run(plan: KernelPlan): Promise<KernelCheckpoint> {
    validatePlan(plan);
    const restored = await this.options.checkpoints.load(plan.id);
    const state = restored ? copyCheckpoint(restored) : initialCheckpoint(plan.id);
    if (state.planId !== plan.id) throw new Error("Checkpoint belongs to another plan");
    if (state.status === "completed") return state;

    state.status = "running";
    state.waitingFor = undefined;
    state.failure = undefined;

    for (let index = 0; index < plan.steps.length; index += 1) {
      const step = plan.steps[index]!;
      // Completion IDs, rather than only a cursor, make recovery safe from an interrupted save.
      if (state.completedStepIds.includes(step.id)) continue;
      state.nextStep = index;

      const budgetFailure = this.budgetFailure(state.usage, { steps: 1, toolCalls: 0, tokens: 0 });
      if (budgetFailure) return this.stopForBudget(plan.id, state, budgetFailure);

      state.currentStepId = step.id;
      await this.options.checkpoints.save(plan.id, copyCheckpoint(state));

      try {
        const result = await this.options.executor.execute(step, {
          planId: plan.id,
          stepIndex: index,
          completedStepIds: [...state.completedStepIds],
          usage: { ...state.usage },
        });
        const charge = normaliseUsage(result);
        state.usage.steps += 1;
        state.usage.toolCalls += charge.toolCalls;
        state.usage.tokens += charge.tokens;

        const exceeded = this.budgetFailure(state.usage);
        if (exceeded) return this.stopForBudget(plan.id, state, exceeded);

        if (result.status === "waiting_user") {
          state.status = "waiting_user";
          state.waitingFor = result.waitingFor;
          await this.options.checkpoints.save(plan.id, copyCheckpoint(state));
          return state;
        }

        state.outputs[step.id] = result.output;
        state.completedStepIds.push(step.id);
        state.nextStep = index + 1;
        state.currentStepId = undefined;
        await this.options.checkpoints.save(plan.id, copyCheckpoint(state));
      } catch (error) {
        state.status = "failed";
        state.failure = { stepId: step.id, message: errorMessage(error) };
        await this.options.checkpoints.save(plan.id, copyCheckpoint(state));
        return state;
      }
    }

    state.status = "completed";
    state.currentStepId = undefined;
    state.nextStep = plan.steps.length;
    await this.options.checkpoints.save(plan.id, copyCheckpoint(state));
    return state;
  }

  async resume(plan: KernelPlan): Promise<KernelCheckpoint> {
    return this.run(plan);
  }

  private budgetFailure(usage: KernelUsage, additional: KernelUsage = { steps: 0, toolCalls: 0, tokens: 0 }): string | null {
    if (usage.steps + additional.steps > this.budget.maxSteps) return "step budget exceeded";
    if (usage.toolCalls + additional.toolCalls > this.budget.maxToolCalls) return "tool-call budget exceeded";
    if (usage.tokens + additional.tokens > this.budget.maxTokens) return "token budget exceeded";
    return null;
  }

  private async stopForBudget(key: string, state: KernelCheckpoint, message: string): Promise<KernelCheckpoint> {
    state.status = "budget_exceeded";
    state.failure = { stepId: state.currentStepId, message };
    await this.options.checkpoints.save(key, copyCheckpoint(state));
    return state;
  }
}

function initialCheckpoint(planId: string): KernelCheckpoint {
  return { planId, status: "pending", nextStep: 0, completedStepIds: [], outputs: {}, usage: { steps: 0, toolCalls: 0, tokens: 0 }, currentStepId: undefined, waitingFor: undefined, failure: undefined };
}

function normaliseUsage(result: StepResult): KernelUsage {
  const toolCalls = result.toolCalls ?? 0;
  const tokens = result.tokens ?? 0;
  if (!Number.isInteger(toolCalls) || toolCalls < 0 || !Number.isFinite(tokens) || tokens < 0) {
    throw new Error("Step usage must be non-negative");
  }
  return { steps: 0, toolCalls, tokens };
}

function validatePlan(plan: KernelPlan): void {
  const ids = new Set<string>();
  for (const step of plan.steps) {
    if (!step.id || ids.has(step.id)) throw new Error(`Invalid or duplicate step id: ${step.id}`);
    ids.add(step.id);
  }
}

function copyCheckpoint(value: KernelCheckpoint): KernelCheckpoint {
  return {
    ...value,
    completedStepIds: [...value.completedStepIds],
    outputs: { ...value.outputs },
    usage: { ...value.usage },
    failure: value.failure ? { ...value.failure } : undefined,
  };
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
