import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/diagnostics/environment_checker.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/core/agent_core.dart' show CancellationSignal;
import 'package:shelly_hermes/core/runtime/hardened_tool_executor.dart';
import 'package:shelly_hermes/core/shell/shell_executor.dart';
import 'package:shelly_hermes/core/tools/registry.dart';
import 'package:shelly_hermes/core/tools/workspace.dart';
import 'package:shelly_hermes/core/runtime/tool_registry.dart';

class _FakeProcessRunner implements ProcessRunner {
  const _FakeProcessRunner({this.supported = true, this.result});

  final bool supported;
  final ShellResult? result;

  @override
  bool get isSupported => supported;

  @override
  Future<ShellResult> run(ShellRequest request,
          {CancellationSignal? cancellation}) async =>
      result ??
      const ShellResult(
          exitCode: 0, duration: Duration(milliseconds: 12));
}

class _HangingRegistry implements AgentToolRegistry {
  @override
  List<ToolSpec> get specs => const [];

  @override
  List<Map<String, dynamic>> openAiToolsJson() => const [];

  @override
  Future<String> execute(ToolCall call) => Completer<String>().future;
}

class _EchoRegistry implements AgentToolRegistry {
  @override
  List<ToolSpec> get specs => const [];

  @override
  List<Map<String, dynamic>> openAiToolsJson() => const [];

  @override
  Future<String> execute(ToolCall call) async => 'a' * 30000;
}

void main() {
  group('EnvironmentChecker', () {
    test('healthy environment: workspace ok, shell ok, gateway ok',
        () async {
      final checker = EnvironmentChecker(
        workspace: MemoryWorkspace(),
        processRunner: const _FakeProcessRunner(),
        baseUrl: 'https://api.example.com/v1',
        modelId: 'test-model',
        apiKey: 'k',
        contextWindowTokens: 128000,
        probeGateway: ({required baseUrl, required model, required apiKey}) =>
            Future.value(const Duration(milliseconds: 88)),
        dshToolCount: 2,
        mcpServerNames: ['github'],
      );

      final results = {for (final c in await checker.run()) c.id: c};

      expect(results['workspace']!.level, CheckLevel.ok);
      expect(results['workspace']!.detail, contains('可读写'));
      expect(results['shell']!.level, CheckLevel.ok);
      expect(results['gateway']!.level, CheckLevel.ok);
      expect(results['gateway']!.detail, contains('88ms'));
      expect(results['context']!.level, CheckLevel.ok);
      expect(results['dsh']!.detail, contains('2 个工具'));
      expect(results['mcp']!.detail, contains('github'));
    });

    test('unsupported shell and unconfigured model degrade to warn',
        () async {
      final checker = EnvironmentChecker(
        workspace: MemoryWorkspace(),
        processRunner: const _FakeProcessRunner(supported: false),
        probeGateway: ({required baseUrl, required model, required apiKey}) =>
            Future.value(const Duration(milliseconds: 1)),
      );

      final results = {for (final c in await checker.run()) c.id: c};

      expect(results['shell']!.level, CheckLevel.warn);
      expect(results['gateway']!.level, CheckLevel.warn);
      expect(results['context']!.level, CheckLevel.warn);
    });

    test('unwritable workspace and failed probe fail loudly', () async {
      final checker = EnvironmentChecker(
        workspace: _ReadOnlyWorkspace(),
        processRunner: const _FakeProcessRunner(
          result: ShellResult(
              exitCode: 1, duration: Duration.zero, stderr: 'no exec'),
        ),
        baseUrl: 'https://api.example.com/v1',
        modelId: 'test-model',
        apiKey: 'k',
        probeGateway: ({required baseUrl, required model, required apiKey}) =>
            Future.error(Exception('refused')),
      );

      final results = {for (final c in await checker.run()) c.id: c};

      expect(results['workspace']!.level, CheckLevel.fail);
      expect(results['shell']!.level, CheckLevel.fail);
      expect(results['gateway']!.level, CheckLevel.fail);
    });
  });

  group('HardenedToolExecutor', () {
    test('oversized results are truncated with a marker', () async {
      final executor = HardenedToolExecutor(registry: _EchoRegistry());
      final result = await executor.execute(
          ToolCall(id: 't1', name: 'x', argumentsJson: ''));
      expect(result.length, lessThan(21000));
      expect(result, contains('已截断'));
    });

    test('oversized results gain a model digest when summarizer succeeds',
        () async {
      String? received;
      final executor = HardenedToolExecutor(
        registry: _EchoRegistry(),
        summarizer: (oversized) async {
          received = oversized;
          return '关键路径 /data/ok,共 3 条记录';
        },
      );
      final result = await executor.execute(
          ToolCall(id: 't3', name: 'x', argumentsJson: ''));

      expect(received, hasLength(30000));
      expect(result, contains('模型摘要如下'));
      expect(result, contains('关键路径 /data/ok'));
      expect(result, contains('原文首尾'));
      expect(result, contains('中间 14000 字符已省略'));
      // Summary + head + tail stays inside the context budget.
      expect(result.length, lessThan(21000));
    });

    test('summarizer failure falls back to plain truncation', () async {
      final executor = HardenedToolExecutor(
        registry: _EchoRegistry(),
        summarizer: (oversized) async => throw Exception('gateway down'),
      );
      final result = await executor.execute(
          ToolCall(id: 't4', name: 'x', argumentsJson: ''));
      expect(result, contains('已截断'));
      expect(result, isNot(contains('模型摘要')));
    });

    test('hanging tools are aborted by the wall-clock timeout', () async {
      final executor = HardenedToolExecutor(
        registry: _HangingRegistry(),
        timeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        executor.execute(ToolCall(id: 't2', name: 'x', argumentsJson: '')),
        throwsA(isA<ToolError>().having(
            (e) => e.toString(), 'message', contains('超时'))),
      );
    });
  });
}

class _ReadOnlyWorkspace implements Workspace {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<void> writeFile(String path, String content) async =>
      throw Exception('workspace read-only');
}
