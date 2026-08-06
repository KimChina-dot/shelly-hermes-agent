import type {
  Blade,
  BladeCapability,
  CircuitState,
  PluginRegistryOptions,
  PluginState,
  PluginStatus,
} from "./types.js";
import { PluginRegistryError } from "./types.js";

interface Entry {
  readonly blade: Blade;
  state: PluginState;
  failures: number;
  openedAt: number | undefined;
  probeInFlight: boolean;
  lifecycle: Promise<void>;
}

const DEFAULT_TIMEOUT_MS = 10_000;
const DEFAULT_FAILURE_THRESHOLD = 3;
const DEFAULT_RESET_MS = 30_000;

/** Platform-neutral registry and reliability boundary for Blade plugins. */
export class PluginRegistry {
  private readonly entries = new Map<string, Entry>();
  private readonly timeoutMs: number;
  private readonly failureThreshold: number;
  private readonly circuitResetMs: number;
  private readonly now: () => number;
  private readonly authorize: PluginRegistryOptions["authorize"];

  constructor(options: PluginRegistryOptions = {}) {
    this.timeoutMs = positive(options.timeoutMs, DEFAULT_TIMEOUT_MS, "timeoutMs");
    this.failureThreshold = positive(
      options.failureThreshold,
      DEFAULT_FAILURE_THRESHOLD,
      "failureThreshold",
    );
    this.circuitResetMs = nonNegative(
      options.circuitResetMs,
      DEFAULT_RESET_MS,
      "circuitResetMs",
    );
    this.now = options.now ?? Date.now;
    this.authorize = options.authorize;
  }

  register(blade: Blade): void {
    validateBlade(blade);
    const id = blade.manifest.id;
    if (this.entries.has(id)) {
      throw new PluginRegistryError(
        `Plugin '${id}' is already registered`,
        "ALREADY_REGISTERED",
        id,
      );
    }
    this.entries.set(id, {
      blade,
      state: "stopped",
      failures: 0,
      openedAt: undefined,
      probeInFlight: false,
      lifecycle: Promise.resolve(),
    });
  }

  async unregister(id: string): Promise<Blade | undefined> {
    const entry = this.entries.get(id);
    if (!entry) return undefined;
    await this.stop(id);
    // Do not delete a replacement registered by user code during stop().
    if (this.entries.get(id) === entry) this.entries.delete(id);
    return entry.blade;
  }

  has(id: string): boolean {
    return this.entries.has(id);
  }

  get(id: string): Blade | undefined {
    return this.entries.get(id)?.blade;
  }

  list(): readonly Blade[] {
    return Array.from(this.entries.values(), ({ blade }) => blade);
  }

  status(id: string): PluginStatus {
    const entry = this.require(id);
    return {
      id,
      state: entry.state,
      circuit: this.circuitState(entry),
      consecutiveFailures: entry.failures,
    };
  }

  async start(id: string): Promise<void> {
    const entry = this.require(id);
    return this.queueLifecycle(entry, async () => {
      if (entry.state === "running") return;
      entry.state = "starting";
      try {
        await entry.blade.start?.();
        entry.state = "running";
      } catch (error) {
        entry.state = "stopped";
        throw error;
      }
    });
  }

  async stop(id: string): Promise<void> {
    const entry = this.require(id);
    return this.queueLifecycle(entry, async () => {
      if (entry.state === "stopped") return;
      entry.state = "stopping";
      try {
        await entry.blade.stop?.();
      } finally {
        entry.state = "stopped";
        entry.failures = 0;
        entry.openedAt = undefined;
        entry.probeInFlight = false;
      }
    });
  }

  async invoke<TOutput = unknown>(
    id: string,
    capability: BladeCapability,
    input?: unknown,
    options: { timeoutMs?: number } = {},
  ): Promise<TOutput> {
    const entry = this.require(id);
    if (entry.state !== "running") {
      throw new PluginRegistryError(
        `Plugin '${id}' is not running`,
        "NOT_RUNNING",
        id,
      );
    }

    await this.assertAuthorized(entry, capability);
    const isProbe = this.acquireCircuit(entry, id);
    const timeoutMs = positive(options.timeoutMs, this.timeoutMs, "timeoutMs");
    const controller = typeof AbortController === "undefined"
      ? undefined
      : new AbortController();

    try {
      // Promise.resolve().then also converts a synchronous plugin throw to rejection.
      const invocation = Promise.resolve().then(() =>
        entry.blade.invoke(capability, input, {
          pluginId: id,
          capability,
          ...(controller ? { signal: controller.signal } : {}),
        }),
      ) as Promise<TOutput>;
      const result = await withTimeout(invocation, timeoutMs, id, controller);
      entry.failures = 0;
      entry.openedAt = undefined;
      return result;
    } catch (error) {
      entry.failures += 1;
      if (entry.failures >= this.failureThreshold) entry.openedAt = this.now();
      throw error;
    } finally {
      if (isProbe) entry.probeInFlight = false;
    }
  }

  private require(id: string): Entry {
    const entry = this.entries.get(id);
    if (!entry) {
      throw new PluginRegistryError(
        `Plugin '${id}' is not registered`,
        "NOT_REGISTERED",
        id,
      );
    }
    return entry;
  }

  private async assertAuthorized(entry: Entry, capability: string): Promise<void> {
    const declared = entry.blade.manifest.capabilities.includes(capability);
    const hostAllowed = declared && (this.authorize
      ? await this.authorize({
          pluginId: entry.blade.manifest.id,
          capability,
          manifest: entry.blade.manifest,
        })
      : true);
    if (!hostAllowed) {
      throw new PluginRegistryError(
        `Plugin '${entry.blade.manifest.id}' is not authorized for '${capability}'`,
        "CAPABILITY_DENIED",
        entry.blade.manifest.id,
      );
    }
  }

  private circuitState(entry: Entry): CircuitState {
    if (entry.openedAt === undefined) return "closed";
    return this.now() - entry.openedAt >= this.circuitResetMs
      ? "half-open"
      : "open";
  }

  private acquireCircuit(entry: Entry, id: string): boolean {
    const state = this.circuitState(entry);
    if (state === "open" || (state === "half-open" && entry.probeInFlight)) {
      throw new PluginRegistryError(
        `Circuit for plugin '${id}' is open`,
        "CIRCUIT_OPEN",
        id,
      );
    }
    if (state === "half-open") {
      entry.probeInFlight = true;
      return true;
    }
    return false;
  }

  private queueLifecycle(entry: Entry, operation: () => Promise<void>): Promise<void> {
    const result = entry.lifecycle.then(operation, operation);
    entry.lifecycle = result.catch(() => undefined);
    return result;
  }
}

function validateBlade(blade: Blade): void {
  const manifest = blade?.manifest;
  const valid = manifest &&
    typeof manifest.id === "string" && manifest.id.trim().length > 0 &&
    typeof manifest.version === "string" && manifest.version.trim().length > 0 &&
    Array.isArray(manifest.capabilities) &&
    manifest.capabilities.every((value) => typeof value === "string" && value.length > 0) &&
    new Set(manifest.capabilities).size === manifest.capabilities.length &&
    typeof blade.invoke === "function";
  if (!valid) {
    throw new PluginRegistryError("Invalid Blade manifest or implementation", "INVALID_MANIFEST");
  }
}

function positive(value: number | undefined, fallback: number, name: string): number {
  const result = value ?? fallback;
  if (!Number.isFinite(result) || result <= 0) throw new RangeError(`${name} must be positive`);
  return result;
}

function nonNegative(value: number | undefined, fallback: number, name: string): number {
  const result = value ?? fallback;
  if (!Number.isFinite(result) || result < 0) throw new RangeError(`${name} must be non-negative`);
  return result;
}

function withTimeout<T>(
  promise: Promise<T>,
  timeoutMs: number,
  id: string,
  controller?: AbortController,
): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => {
      controller?.abort();
      reject(new PluginRegistryError(
        `Plugin '${id}' invocation timed out after ${timeoutMs}ms`,
        "TIMEOUT",
        id,
      ));
    }, timeoutMs);
    promise.then(
      (value) => { clearTimeout(timer); resolve(value); },
      (error) => { clearTimeout(timer); reject(error); },
    );
  });
}
