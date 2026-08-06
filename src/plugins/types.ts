export type BladeCapability = string;

export interface BladeManifest {
  /** Stable, unique plugin identifier. */
  readonly id: string;
  readonly name?: string;
  readonly version: string;
  /** Capabilities this blade is allowed to expose. */
  readonly capabilities: readonly BladeCapability[];
}

export interface BladeContext {
  readonly pluginId: string;
  readonly capability: BladeCapability;
  readonly signal?: AbortSignal;
}

export interface Blade<TInput = unknown, TOutput = unknown> {
  readonly manifest: BladeManifest;
  start?(): void | Promise<void>;
  stop?(): void | Promise<void>;
  invoke(
    capability: BladeCapability,
    input: TInput,
    context: BladeContext,
  ): TOutput | Promise<TOutput>;
}

export type PluginState = "stopped" | "starting" | "running" | "stopping";
export type CircuitState = "closed" | "open" | "half-open";

export interface PluginStatus {
  readonly id: string;
  readonly state: PluginState;
  readonly circuit: CircuitState;
  readonly consecutiveFailures: number;
}

export interface AuthorizationRequest {
  readonly pluginId: string;
  readonly capability: BladeCapability;
  readonly manifest: BladeManifest;
}

export type CapabilityAuthorizer = (
  request: AuthorizationRequest,
) => boolean | Promise<boolean>;

export interface PluginRegistryOptions {
  /** Per-call timeout in milliseconds. Defaults to 10 seconds. */
  readonly timeoutMs?: number;
  /** Consecutive invocation failures before opening the circuit. Defaults to 3. */
  readonly failureThreshold?: number;
  /** Time before one half-open probe is permitted. Defaults to 30 seconds. */
  readonly circuitResetMs?: number;
  /** Additional host policy. A declared capability is required regardless. */
  readonly authorize?: CapabilityAuthorizer;
  /** Injectable monotonic-enough wall clock for deterministic hosts/tests. */
  readonly now?: () => number;
}

export type PluginErrorCode =
  | "INVALID_MANIFEST"
  | "ALREADY_REGISTERED"
  | "NOT_REGISTERED"
  | "NOT_RUNNING"
  | "CAPABILITY_DENIED"
  | "TIMEOUT"
  | "CIRCUIT_OPEN";

export class PluginRegistryError extends Error {
  constructor(
    message: string,
    readonly code: PluginErrorCode,
    readonly pluginId?: string,
    options?: { cause?: unknown },
  ) {
    super(message);
    this.name = "PluginRegistryError";
    if (options && "cause" in options) {
      Object.defineProperty(this, "cause", {
        configurable: true,
        value: options.cause,
      });
    }
  }
}
