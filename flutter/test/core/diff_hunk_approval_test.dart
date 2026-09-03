import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/diff_hunk_approval.dart';
import 'package:shelly_hermes/core/models.dart';

Map<String, dynamic> argsOf(ToolCall call) =>
    jsonDecode(call.argumentsJson) as Map<String, dynamic>;

void main() {
  group('expand', () {
    test('splits apply_patch into numbered per-hunk calls', () {
      final call = ToolCall(
        id: 'p1',
        name: 'apply_patch',
        argumentsJson:
            '{"path":"lib/a.dart","patch":"@@ -1,2 +1,2 @@\\n-a\\n+b\\n@@ -3,2 +3,2 @@\\n-c\\n+d"}',
      );

      final hunks = DiffHunkApproval.expand(call);

      expect(hunks.length, 2);
      expect(hunks[0].id, 'p1:hunk-1');
      expect(hunks[0].name, 'apply_patch_hunk');
      expect(argsOf(hunks[0])['path'], 'lib/a.dart');
      expect(argsOf(hunks[0])['hunk_index'], 1);
      expect(argsOf(hunks[0])['hunk_count'], 2);
      expect(argsOf(hunks[0])['hunk'], '@@ -1,2 +1,2 @@\n-a\n+b');
      expect(hunks[1].id, 'p1:hunk-2');
      expect(argsOf(hunks[1])['hunk_index'], 2);
      expect(argsOf(hunks[1])['hunk'], '@@ -3,2 +3,2 @@\n-c\n+d');
    });

    test('passes through non-apply_patch calls untouched', () {
      const call = ToolCall(id: 't1', name: 'read_file', argumentsJson: '{"path":"x"}');

      final result = DiffHunkApproval.expand(call);

      expect(result, [call]);
    });

    test('passes through apply_patch without hunk headers', () {
      final call = ToolCall(
        id: 'p1',
        name: 'apply_patch',
        argumentsJson: '{"path":"a.txt","patch":"plain line"}',
      );

      final result = DiffHunkApproval.expand(call);

      expect(result, [call]);
    });

    test('passes through when path or patch missing', () {
      final call = ToolCall(id: 'p1', name: 'apply_patch', argumentsJson: '{"patch":"@@ x"}');

      expect(DiffHunkApproval.expand(call), [call]);
    });

    test('handles CRLF line endings inside the patch', () {
      final call = ToolCall(
        id: 'p1',
        name: 'apply_patch',
        argumentsJson:
            '{"path":"a.txt","patch":"@@ -1 +1 @@\\r\\n-old\\r\\n+new\\r\\n@@ -5 +5 @@\\r\\n-a\\r\\n+b"}',
      );

      final hunks = DiffHunkApproval.expand(call);

      expect(hunks.length, 2);
      expect(argsOf(hunks[0])['hunk'], contains('-old'));
      expect(argsOf(hunks[1])['hunk'], contains('+b'));
    });

    test('escapes special characters when re-encoding arguments', () {
      // Path contains a real backslash; patch contains a quote and a tab.
      // Build the JSON via jsonEncode so the input itself is well-formed.
      final call = ToolCall(
        id: 'p1',
        name: 'apply_patch',
        argumentsJson: jsonEncode({
          'path': 'a\\b.txt',
          'patch': '@@ -1 +1 @@\n-quote: "x"\n+tab\there',
        }),
      );

      final hunks = DiffHunkApproval.expand(call);
      final collapsed = DiffHunkApproval.collapse(hunks);

      expect(argsOf(collapsed)['path'], 'a\\b.txt');
      expect(argsOf(collapsed)['patch'], contains('quote: "x"'));
      expect(argsOf(collapsed)['patch'], contains('tab\there'));
    });
  });

  group('collapse', () {
    ToolCall hunk(int index, String content) => ToolCall(
          id: 'p1:hunk-$index',
          name: 'apply_patch_hunk',
          argumentsJson: jsonEncode({
            'path': 'lib/a.dart',
            'hunk_index': index,
            'hunk_count': 2,
            'hunk': content,
          }),
        );

    test('rebuilds full apply_patch from approved hunks in order', () {
      final collapsed = DiffHunkApproval.collapse([hunk(2, 'line-two'), hunk(1, 'line-one')]);

      expect(collapsed.id, 'p1');
      expect(collapsed.name, 'apply_patch');
      final args = argsOf(collapsed);
      expect(args.containsKey('hunk_index'), isFalse);
      expect(args['path'], 'lib/a.dart');
      // Ordered by hunk_index despite input order.
      final patch = args['patch'] as String;
      expect(patch.indexOf('line-one'), lessThan(patch.indexOf('line-two')));
    });

    test('rejects empty input and foreign tool names', () {
      expect(() => DiffHunkApproval.collapse([]), throwsArgumentError);

      expect(
        () => DiffHunkApproval.collapse([
          const ToolCall(id: 't1', name: 'read_file', argumentsJson: '{}'),
        ]),
        throwsArgumentError,
      );
    });

    test('rejects hunks from different files', () {
      final mixed = [
        ToolCall(
          id: 'p1:hunk-1',
          name: 'apply_patch_hunk',
          argumentsJson: '{"path":"a.dart","hunk_index":1,"hunk_count":1,"hunk":"x"}',
        ),
        ToolCall(
          id: 'p2:hunk-1',
          name: 'apply_patch_hunk',
          argumentsJson: '{"path":"b.dart","hunk_index":1,"hunk_count":1,"hunk":"y"}',
        ),
      ];

      expect(() => DiffHunkApproval.collapse(mixed), throwsArgumentError);
    });

    test('round-trips expand → collapse preserving content', () {
      final original = ToolCall(
        id: 'p9',
        name: 'apply_patch',
        argumentsJson:
            '{"path":"src/x.dart","patch":"@@ -1,3 +1,3 @@\\n-a1\\n+b1\\n-c1\\n@@ -9,1 +9,1 @@\\n-tail\\n+head"}',
      );

      final hunks = DiffHunkApproval.expand(original);
      final collapsed = DiffHunkApproval.collapse(hunks);

      expect(collapsed.id, 'p9');
      expect(collapsed.name, 'apply_patch');
      final patch = argsOf(collapsed)['patch'] as String;
      expect(patch, contains('-a1'));
      expect(patch, contains('+head'));
      expect(patch, contains('-tail'));
    });
  });
}
