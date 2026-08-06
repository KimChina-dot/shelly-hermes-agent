import type { Capability, RiskLevel, ToolRequest } from "../core/types.js";

export type PolicyAction = "allow" | "confirm" | "deny";

export interface PolicyDecision {
  readonly action: PolicyAction;
  readonly reason: string;
  readonly missingCapabilities: readonly Capability[];
}

export interface PolicyEngineOptions {
  /** Capabilities delegated to this execution context. */
  readonly capabilities?: Iterable<Capability>;
  /** Risks which may run without interaction. Defaults to read and sandboxed. */
  readonly allowRisks?: Iterable<RiskLevel>;
  /** Risks which must be explicitly approved. */
  readonly confirmRisks?: Iterable<RiskLevel>;
}

/**
 * Platform-neutral policy evaluation. Capability failure always wins over risk:
 * confirmation must never be used to acquire a capability the caller lacks.
 */
export class PolicyEngine {
  private readonly capabilities: ReadonlySet<Capability>;
  private readonly allowed: ReadonlySet<RiskLevel>;
  private readonly confirmed: ReadonlySet<RiskLevel>;

  constructor(options: PolicyEngineOptions | Iterable<Capability> = {}) {
    const iterable = options != null && Symbol.iterator in Object(options);
    const config: PolicyEngineOptions = iterable
      ? { capabilities: options as Iterable<Capability> }
      : options as PolicyEngineOptions;
    this.capabilities = new Set(config.capabilities ?? []);
    this.allowed = new Set(config.allowRisks ?? ["read", "sandboxed"]);
    this.confirmed = new Set(config.confirmRisks ?? ["review", "dangerous", "external"]);
  }

  evaluate(request: ToolRequest): PolicyDecision {
    const missing = [...new Set(request.requiredCapabilities)].filter(
      capability => !this.capabilities.has(capability),
    );
    if (missing.length > 0) {
      return { action: "deny", reason: `Missing capabilities: ${missing.join(", ")}`, missingCapabilities: missing };
    }
    if (this.allowed.has(request.risk)) {
      return { action: "allow", reason: `Risk '${request.risk}' is allowed`, missingCapabilities: [] };
    }
    if (this.confirmed.has(request.risk)) {
      return { action: "confirm", reason: `Risk '${request.risk}' requires confirmation`, missingCapabilities: [] };
    }
    return { action: "deny", reason: `Risk '${request.risk}' is not permitted`, missingCapabilities: [] };
  }

  decide(request: ToolRequest): PolicyDecision {
    return this.evaluate(request);
  }
}
