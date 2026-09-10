# Trajectory-Level Eval Baseline (PHASE 46)

A self-contained, deterministic evaluation suite for the real `AgentCore`
loop. Following Anthropic's evals guidance, it grades **what the agent
produced** — the outcome in the environment plus a trajectory rubric — not
the exact path it took to get there. There is no LLM judge: every rubric
check is plain Dart code, so the baseline is fully reproducible and safe to
run in CI.

## What it exercises

Each scenario drives the **real** `AgentCore` engine end-to-end:

| Component | Real or scripted |
| --- | --- |
| `AgentCore` round loop, approvals, checkpoints, limits | real |
| `WorkspaceToolRegistry` (read_file, write_file, apply_patch, list_files, exists, search_files) | real |
| `ShellToolRegistry` + `ShellPolicy` + `ShellRiskClassifier` (risk grading, `critical` → block) | real |
| `ToolPolicy.standard` + `ShellApprovalPolicy` (approval routing) | real |
| Model gateway | scripted (`ScriptedGateway` replays queued `ModelReply`s) |
| Workspace | `MemoryWorkspace` seeded per scenario |
| Shell process runner | `_NeverExecuteRunner` — refuses to spawn anything; evals are hermetic |

The engine can only do what the script and the real tool registries let it
do, so a green run means the *engine + policy + tools* contract still holds.

## How to run

```bash
cd flutter
flutter test test/eval
```

Or run a single file:

```bash
flutter test test/eval/trajectory_test.dart
```

The suite is deterministic: no network, no filesystem outside the process,
no timing dependencies. All scenarios must pass on every commit.

## The baseline scenarios

| # | Name | What it pins down |
| --- | --- | --- |
| 1 | `01-read-and-summarize` | read_file then answer from file content; seed unchanged |
| 2 | `02-write-new-file` | write_file creates a new file; mutating call routes through approval |
| 3 | `03-apply-patch-existing` | apply_patch hunk semantics on an existing file |
| 4 | `04-search-then-read` | search_files locates, read_file confirms; strict call order |
| 5 | `05-create-then-edit` | multi-step create (write_file) then edit (apply_patch) in one task |
| 6 | `06-tool-error-recovery` | first call returns an error string (shell unavailable); agent recovers with a workspace tool |
| 7 | `07-block-destructive-command` | `rm -rf` graded `critical` by `ShellRiskClassifier`, blocked by `ShellPolicy`; workspace intact, no process spawned |
| 8 | `08-memory-injected-answer` | system prompt composed via `systemPromptWithMemory` + `personaWithToolRules` (same helpers `lib/state/chat_session.dart` uses); memory fact + tool rules present |
| 9 | `09-no-tool-direct-answer` | one-round answer, zero tool calls |
| 10 | `10-list-files-then-exists` | list_files inventory then exists verification |

## The Brain-path scenarios (PHASE 11)

A scenario with a `brain: BrainScript(...)` runs the production preflight
combination before the engine: `MeteredGateway` wraps the shared scripted
transport, `Brain.decide` classifies (and plans for multiStep intents),
the steps seed the notes registry, and the charged tokens become
`AgentCore.initialConsumedTokens`. The opening system prompt is composed
exactly like `chat_session.dart` (persona + tool rules + the seeded
「当前计划」 block), and every engine round refreshes the recitation
through the REAL `recitationBodyDecorator` — the same code the OpenAI
gateway runs per round.

| # | Name | What it pins down |
| --- | --- | --- |
| 11 | `11-brain-multistep-plan` | multiStep verdict seeds the plan; every engine request carries 「当前计划」 + the step text; gateway calls == classify + plan + rounds |
| 12 | `12-brain-quickanswer-bypass` | quickAnswer verdict: planner never called (exact gateway-call count), prompt carries no plan block |
| 13 | `13-brain-budget-charge` | preflight tokens join the one 64K budget: final `checkpoint.consumedTokens` == preflight + rounds (exact value) |
| 14 | `14-brain-failopen` | classify call throws: task still completes, no plan block, zero preflight charge, only round tokens consumed |
| 15 | `15-plan-tool-recitation-refresh` | no Brain: the `plan` tool updates the plan in round one and the NEXT request's recitation mirror reflects the new steps (PHASE 46 semantics); round one stays clean; plan auto-runs, workspace untouched |

## What the rubric grades

Every scenario carries a list of `RubricCheck`s evaluated against
`EvalRunEvidence`:

**Outcome checks** (state in the environment after the run):
- workspace file contents (exact equality / presence / absence)
- whole-workspace immutability (`workspaceUnchanged`)
- final assistant message content
- no shell process was ever spawned (`shellNeverExecuted`)

**Trajectory checks** (how the run unfolded):
- tool sequence in execution order (`toolSequence`) or membership
  (`usedTool` / `noToolNamed`)
- model rounds and tool-call budget (`modelRoundsAtMost`, `toolCallsAtMost`)
- approval routing of mutating/dangerous tools (`approvalAskedFor`)
- tool results / errors observed (`toolResultContains`, `noToolFailures`)
- system prompt composition (`systemPromptContains`)

A run prints one line per scenario:

```
PASS 01-read-and-summarize (rounds=2 tools=1)
FAIL 03-apply-patch-existing (rounds=2 tools=1 failed=[outcome: lib/config.dart equals expected content])
```

`trajectory_test.dart` also includes two negative controls (a
self-contradictory scenario must fail with its check names) so an
always-green harness cannot hide regressions.

## How to add a scenario

1. Open `test/eval/scenarios/eval_scenarios.dart`.
2. Append an `EvalScenario` to the list returned by `evalScenarios()`:
   - `name`: unique, greppable (keep the `NN-kebab-case` convention).
   - `userTask`: the user message handed to the agent.
   - `seedFiles`: workspace files present before the run.
   - `script`: queued `ModelReply`s — tool-call rounds first, final answer
     last. Keep arguments exactly matching each tool's real schema
     (`path`, `query`, `prefix`, `content`, `patch`, `command`).
   - `rubric`: compose from the check builders in the same file
     (`completed()`, `fileEquals`, `toolSequence`, `usedTool`, …). Prefer
     outcome checks; add trajectory checks for contracts worth pinning
     (order, approval routing, budgets).
3. If the baseline count changes, update the `hasLength(15)` expectation in
   `trajectory_test.dart`.

Keep scenarios deterministic and hermetic: no clocks, no randomness, no
real processes. If a scenario needs a new check builder, add it next to the
existing ones in `eval_scenarios.dart`.
