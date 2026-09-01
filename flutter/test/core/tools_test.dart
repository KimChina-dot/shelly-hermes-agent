import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/core/tools/audit.dart';
import 'package:shelly_hermes/core/tools/registry.dart';
import 'package:shelly_hermes/core/tools/workspace.dart';

ToolCall call(String name, Map<String, dynamic> args) => ToolCall(
      id: 't-$name',
      name: name,
      argumentsJson: args.isEmpty ? '{}' : jsonEncode(args),
    );

void main() {
  group('MemoryWorkspace', () {
    test('read, write, exists, list and search', () async {
      final ws = MemoryWorkspace({'src/a.dart': 'void main() {}', 'docs/readme.md': 'hello'});
      await ws.writeFile('src/b.dart', 'x');

      expect(await ws.exists('src/a.dart'), isTrue);
      expect(await ws.readFile('src/b.dart'), 'x');
      expect(await ws.readFile('missing.txt'), isNull);
      expect(await ws.listFiles('src/'), ['src/a.dart', 'src/b.dart']);
      expect(await ws.searchFiles('main'), ['src/a.dart']);
      expect(await ws.searchFiles('HELLO'), ['docs/readme.md']);
      expect(await ws.searchFiles('zzz'), isEmpty);
    });
  });

  group('applyPatchToContent', () {
    test('splices hunks by context', () {
      final original = 'void main() {\n  print("a");\n  print("b");\n}\n';
      // Context lines are the diff prefix (one space) + the original line.
      const patch = '@@ -1,3 +1,3 @@\n void main() {\n-  print("a");\n+  print("A");\n   print("b");\n';

      final updated = applyPatchToContent(original, patch);

      expect(updated, 'void main() {\n  print("A");\n  print("b");\n}\n');
    });

    test('applies later hunks after earlier replacements', () {
      final original = 'one\ntwo\nthree\nfour\n';
      const patch = '@@ -1,2 +1,2 @@\n one\n-two\n+TWO\n@@ -3,2 +3,2 @@\n three\n-four\n+FOUR\n';

      expect(applyPatchToContent(original, patch), 'one\nTWO\nthree\nFOUR\n');
    });

    test('throws and leaves content untouched on context mismatch', () {
      const original = 'a\nb\nc';
      const patch = '@@ -1,2 +1,2 @@\n x\n-y\n+z';

      expect(() => applyPatchToContent(original, patch), throwsA(isA<PatchException>()));
    });

    test('rejects patches without hunks', () {
      expect(
        () => applyPatchToContent('a\nb', 'not a patch'),
        throwsA(isA<PatchException>()),
      );
    });
  });

  group('WorkspaceToolRegistry', () {
    test('executes read tools against the workspace', () async {
      final registry = WorkspaceToolRegistry(
        workspace: MemoryWorkspace({'a.txt': 'content of a'}),
      );

      expect(
        await registry.execute(call('read_file', {'path': 'a.txt'})),
        'content of a',
      );
      expect(await registry.execute(call('exists', {'path': 'a.txt'})), 'true');
      expect(
        await registry.execute(call('search_files', {'query': 'a.txt'})),
        'a.txt',
      );
      expect(
        await registry.execute(call('list_files', {'prefix': ''})),
        'a.txt',
      );
    });

    test('write_file then read back; apply_patch edits content', () async {
      final ws = MemoryWorkspace();
      final registry = WorkspaceToolRegistry(workspace: ws);

      await registry.execute(call('write_file', {'path': 'f.txt', 'content': 'one\ntwo\n'}));
      await registry.execute(call(
        'apply_patch',
        {'path': 'f.txt', 'patch': '@@ -1,2 +1,2 @@\n one\n-two\n+TWO\n'},
      ));

      expect(await ws.readFile('f.txt'), 'one\nTWO\n');
    });

    test('read_file on missing file throws ToolError', () async {
      final registry = WorkspaceToolRegistry(workspace: MemoryWorkspace());

      await expectLater(
        registry.execute(call('read_file', {'path': 'nope'})),
        throwsA(isA<ToolError>()),
      );
    });

    test('denied tools return a policy error without touching workspace', () async {
      final ws = MemoryWorkspace();
      final registry = WorkspaceToolRegistry(
        workspace: ws,
        policy: const ToolPolicy(levels: {'write_file': ToolPolicyLevel.deny}),
      );

      final result = await registry.execute(call('write_file', {'path': 'x', 'content': 'y'}));

      expect(result, contains('denied by policy'));
      expect(ws.files, isEmpty);
    });

    test('standard policy auto-approves reads and confirms writes', () {
      final policy = ToolPolicy.standard;

      expect(policy.levelFor('read_file'), ToolPolicyLevel.allow);
      expect(policy.levelFor('apply_patch'), ToolPolicyLevel.confirm);
      // Unknown tools default to confirm (fail closed).
      expect(policy.levelFor('mystery'), ToolPolicyLevel.confirm);

      final approval = policy.toApprovalPolicy();
      expect(approval.requiresApproval(const ToolCall(id: '1', name: 'read_file', argumentsJson: '')), isFalse);
      expect(approval.requiresApproval(const ToolCall(id: '2', name: 'write_file', argumentsJson: '')), isTrue);
    });

    test('missing required argument fails with ToolArgumentsException', () async {
      final registry = WorkspaceToolRegistry(workspace: MemoryWorkspace());

      await expectLater(
        registry.execute(call('read_file', {})),
        throwsA(isA<ToolArgumentsException>()),
      );
    });
  });

  group('JsonlAuditLog', () {
    test('records tool start/finish and approval events as JSONL', () {
      final sink = InMemoryAuditSink();
      final log = JsonlAuditLog(sink: sink, clock: () => DateTime(2026, 1, 1));

      log.onEvent(const ToolStarted('t1', 'write_file', '{"path":"a"}'));
      log.onEvent(const ToolFinished(
        toolCallId: 't1',
        toolName: 'write_file',
        durationMillis: 42,
        succeeded: true,
        result: 'written',
      ));
      log.onEvent(const ApprovalWaiting(ToolCall(id: 't1', name: 'write_file', argumentsJson: '')));
      log.onEvent(const ApprovalFinished(
        call: ToolCall(id: 't1', name: 'write_file', argumentsJson: ''),
        durationMillis: 10,
        decision: ApprovalDecision.approve,
      ));

      expect(sink.lines.length, 4);
      expect(sink.lines[0], contains('"event":"tool_started"'));
      expect(sink.lines[0], contains('"ts":"2026-01-01T00:00:00.000"'));
      expect(sink.lines[1], contains('"succeeded":true'));
      expect(sink.lines[2], contains('"event":"approval_waiting"'));
      expect(sink.lines[3], contains('"decision":"approve"'));
    });

    test('throws inside the sink are swallowed', () {
      final log = JsonlAuditLog(sink: _ExplodingSink(), clock: DateTime.now);

      expect(
        () => log.onEvent(const ToolStarted('t1', 'x', '')),
        returnsNormally,
      );
    });
  });
}

class _ExplodingSink implements AuditSink {
  @override
  void write(String line) => throw StateError('disk full');
}
