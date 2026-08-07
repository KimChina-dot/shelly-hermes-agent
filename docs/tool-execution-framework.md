# Tool execution framework audit and design

## Audit findings

The repository had good individual primitives but no mandatory execution boundary:

- `workspace-tools.ts` asked for confirmation inside selected tools, so plugins/new tools could bypass approval and policy.
- `PolicyEngine` was not wired into `CodingAgent`; tool declarations did not carry capabilities/risk.
- output truncation happened only after execution in the agent and lost structured metadata.
- plugin capability authorization was separate from tool risk approval and plugin output was not audited/truncated.
- checkpoint persistence represented agent progress, not a reversible workspace snapshot.
- no append-only execution audit, patch preview, or automatic rollback existed.
- workspace tools import Node filesystem APIs directly; keep these host tools out of the portable core and expose filesystem enumeration through a future port.

## Implemented architecture

`ToolExecutionFramework` is the one model-facing registry and invocation choke point:

1. register a tool with schema plus immutable `capabilities`, `risk`, mutation/checkpoint and result-limit metadata;
2. emit a redacted `requested` JSONL event;
3. evaluate `PolicyEngine` (missing capability always denies);
4. build an optional patch/operation preview;
5. request approval only when policy returns `confirm`;
6. create a Git snapshot before mutation;
7. execute with `AbortSignal`;
8. centrally truncate JSON output with head/tail metadata;
9. generate the post-execution diff;
10. audit success/failure and automatically rollback a failed mutation.

The framework can produce existing `AgentTool[]` via `asAgentTools()`, allowing incremental host migration without changing model APIs. Plugin capabilities should be exposed as `ExecutionTool` wrappers and invoked through this framework rather than calling `PluginRegistry.invoke` from an agent directly.

## Portability

Core orchestration imports no `node:*` modules. Persistence, approval, clock and Git are ports. `PortableGitCheckpoints` calls `git` with an executable and argv through `ProcessPort`, never shell command strings, making quoting behavior portable across Android and Windows.

Hosts should compose:

- Android: Android text-store/clock/approval UI + Android process adapter.
- Windows: Node text-store/clock/CLI approval + Windows process adapter.
- Audit path defaults to `.shelly/audit.jsonl`; hosts may choose app-private storage.

## Security notes / next hardening

- Approval must be bound to request ID and preview hash in remote/async UIs; the current synchronous port is suitable for local MVP hosts.
- Git rollback intentionally uses `reset --hard` and `clean -fd`; only invoke it after explicit approval and on a dedicated workspace. Ignored files are preserved.
- `git stash create` does not include untracked files in its tree. Existing untracked files are therefore not fully restorable if a tool overwrites them. Production should add a host-side content-addressed backup for untracked paths or require a clean repository before mutation.
- Audit sink failures fail closed because execution cannot continue without an audit record.
- Sensitive-key redaction is structural; production should additionally apply configured value fingerprints and size limits before audit serialization.
