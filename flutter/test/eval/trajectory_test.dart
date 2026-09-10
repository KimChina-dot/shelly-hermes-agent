// PHASE 46 — trajectory-level evaluation baseline.
//
// Runs every scenario from `scenarios/eval_scenarios.dart` through the REAL
// AgentCore loop (scripted gateway, in-memory workspace, real tool
// registries with real policy) and prints a PASS/FAIL summary line per
// scenario including the names of failed rubric checks. Deterministic by
// construction: no network, no filesystem, no LLM judge.
//
// What the rubric grades (Anthropic evals guidance: grade what the agent
// produced, not the path it took to get there):
// - OUTCOME: workspace file state after the run, shell processes spawned,
//   final assistant answer.
// - TRAJECTORY: which tools were used / forbidden, call order, model rounds,
//   approval routing, and — for the memory scenario — the composed system
//   prompt the model actually received.
import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/memory/memory_store.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/state/chat_session.dart'
    show personaWithToolRules, systemPromptWithMemory;

import 'scenarios/eval_scenarios.dart';

void main() {
  final scenarios = evalScenarios();
  final scenarioNames = scenarios.map((s) => s.name).toList();

  test('scenario set is the fixed fifteen-scenario baseline', () {
    expect(scenarios, hasLength(15));
    expect(
      scenarioNames.toSet().length,
      15,
      reason: 'scenario names must be unique so report lines stay greppable',
    );
  });

  test('every scenario passes its deterministic rubric (baseline)', () async {
    final report = <String>[];

    for (final scenario in scenarios) {
      String? systemPrompt;
      if (scenario.composeMemoryPrompt) {
        // Compose exactly like chat_session.dart does for a fresh send:
        // persona + tool rules + 「长期记忆」 block.
        systemPrompt = systemPromptWithMemory(
          persona: personaWithToolRules(scenario.persona),
          memories: scenario.memories,
        );
      } else if (scenario.systemPrompt != null) {
        systemPrompt = scenario.systemPrompt;
      }
      // Brain/notes scenarios need no prompt here: runScenario composes the
      // production opening prompt itself (the recitation block must reflect
      // state seeded by the preflight, which only exists inside the harness).

      final outcome = await runScenario(scenario, systemPrompt: systemPrompt);

      final status = outcome.passed ? 'PASS' : 'FAIL';
      final detail = <String>[
        'rounds=${outcome.modelRounds}',
        'tools=${outcome.toolCallCount}',
        if (outcome.runError != null) 'runError=${outcome.runError}',
        if (outcome.failedChecks.isNotEmpty)
          'failed=[${outcome.failedChecks.join('; ')}]',
      ].join(' ');
      final line = '$status ${scenario.name} ($detail)';
      report.add(line);
      // ignore: avoid_print
      print(line);
    }

    final failures = report.where((line) => line.startsWith('FAIL')).toList();
    expect(
      failures,
      isEmpty,
      reason: 'deterministic baseline must be green:\n${report.join('\n')}',
    );
  });

  test('negative control: a self-contradictory scenario fails its rubric',
      () async {
    // Guards against an always-green harness: a scenario whose seeded
    // workspace contradicts its own outcome check must FAIL, with the
    // failed check names reported.
    final outcome = await runScenario(
      EvalScenario(
        name: 'control-corrupted-outcome',
        description: 'Negative control for the harness itself.',
        userTask: 'x',
        script: [ModelReply(content: 'done')],
        seedFiles: {'lib/keep.txt': 'original'},
        rubric: [
          completed(),
          fileEquals('lib/keep.txt', 'tampered'),
          usedTool('read_file'),
        ],
      ),
    );    expect(outcome.passed, isFalse);
    expect(outcome.failedChecks, hasLength(2));
    expect(
      outcome.failedChecks.any((c) => c.contains('lib/keep.txt')),
      isTrue,
    );
    expect(
      outcome.failedChecks.any((c) => c.contains('used tool read_file')),
      isTrue,
    );
  });

  test('memory composition omits the memory block when no facts exist', () {
    final prompt = systemPromptWithMemory(
      persona: personaWithToolRules('你是 Shelly。'),
      memories: const <MemoryFact>[],
    );
    expect(prompt, isNotNull);
    expect(prompt, contains('Shelly'));
    expect(prompt, isNot(contains('长期记忆')));
  });
}
