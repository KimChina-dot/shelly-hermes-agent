// PHASE 20 (plan P13): platform-channel contract tests for the
// `dev.shelly/workspace` SAF bridge (`lib/platform/platform_workspace.dart`,
// native side MainActivity.kt:190 — Storage Access Framework document
// tree).
//
// Two contracts per the plan:
//  (a) non-Android host: createWorkspace() must hand out the in-memory
//      fallback — a mock channel handler records the 'dev.shelly/workspace'
//      channel and asserts ZERO traffic while reads/writes round-trip in
//      the sandbox.
//  (b) wire contract: a real PlatformWorkspace() against a mock handler
//      pins every method name and argument shape MainActivity.kt parses
//      (pickDirectory/hasDirectory/forgetDirectory argument-less; readFile/
//      deleteFile/listFiles take the RAW path/prefix; writeFile takes
//      {'path', 'content'}), the decoded return shapes, and the
//      PlatformException degradation for the guarded picks.
//
// The channel wiring itself (ResilientWorkspace sandbox fallback, grant
// flipping) is covered by workspace_fallback_test.dart; this file pins
// only the wire.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/tools/workspace.dart';
import 'package:shelly_hermes/platform/platform_workspace.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dev.shelly/workspace');
  final calls = <MethodCall>[];
  // In-memory model of the SAF document tree the mock native side holds.
  final files = <String, String>{};
  bool hasGrant = false;
  bool refusePicks = false;

  Future<Object?>? handler(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'pickDirectory':
        if (refusePicks) {
          throw PlatformException(code: 'workspace', message: 'cancelled');
        }
        hasGrant = true;
        return 'content://tree/primary%3Ashelly';
      case 'hasDirectory':
        if (refusePicks) {
          throw PlatformException(code: 'workspace', message: 'no grant');
        }
        return hasGrant;
      case 'forgetDirectory':
        if (refusePicks) {
          throw PlatformException(code: 'workspace', message: 'no grant');
        }
        hasGrant = false;
        return null;
      case 'readFile':
        return files[call.arguments as String];
      case 'writeFile':
        final args = call.arguments as Map;
        files[args['path'] as String] = args['content'] as String;
        return null;
      case 'deleteFile':
        return files.remove(call.arguments as String) != null;
      case 'listFiles':
        return files.keys.toList();
    }
    return null;
  }

  setUp(() {
    calls.clear();
    files
      ..clear()
      ..['notes/plan.md'] = 'dinner plan'
      ..['dinner-list.txt'] = 'shopping';
    hasGrant = false;
    refusePicks = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('non-Android host (a): memory sandbox, zero channel traffic', () {
    test('premise: this runner is not the Android host', () {
      expect(isAndroidHost, isFalse,
          reason: 'workspace host-guard tests require a non-Android host');
    });

    test('createWorkspace never touches the workspace channel', () async {
      final ws = createWorkspace();
      expect(ws, isA<MemoryWorkspace>(),
          reason: 'off Android the app must run on the memory sandbox');

      await ws.writeFile('ph20-smoke/notes.md', '第一行');
      expect(await ws.readFile('ph20-smoke/notes.md'), '第一行');
      expect(await ws.exists('ph20-smoke/notes.md'), isTrue);
      await ws.deleteFile('ph20-smoke/notes.md');

      expect(calls, isEmpty,
          reason: 'off Android, the workspace must not touch the channel');
    });
  });

  group('wire contract (b): PlatformWorkspace vs mock handler', () {
    test('pickDirectory/hasDirectory/forgetDirectory are argument-less and '
        'decode the grant lifecycle', () async {
      final ws = PlatformWorkspace();

      expect(await ws.hasDirectory(), isFalse);
      expect(await ws.pickDirectory(), 'content://tree/primary%3Ashelly');
      expect(await ws.hasDirectory(), isTrue);

      await ws.forgetDirectory();
      expect(hasGrant, isFalse,
          reason: 'forgetDirectory must clear the persisted grant');

      expect(
          calls.map((c) => c.method).toList(),
          containsAllInOrder(
              <String>['hasDirectory', 'pickDirectory', 'hasDirectory']));
      for (final call in calls.take(3)) {
        expect(call.arguments, isNull,
            reason: '${call.method} must not carry arguments');
      }
    });

    test('a cancelled picker or missing grant degrades to null/false/no-throw',
        () async {
      refusePicks = true;
      final ws = PlatformWorkspace();

      expect(await ws.pickDirectory(), isNull,
          reason: 'user cancel must surface as null, not an exception');
      expect(await ws.hasDirectory(), isFalse);
      // Must simply complete: nothing was persisted, nothing to forget.
      await ws.forgetDirectory();
    });

    test('readFile takes the raw path; missing files decode to null',
        () async {
      final ws = PlatformWorkspace();

      expect(await ws.readFile('notes/plan.md'), 'dinner plan');
      expect(await ws.readFile('missing.txt'), isNull);

      expect(calls, hasLength(2));
      expect(calls.first.method, 'readFile');
      expect(calls.first.arguments, 'notes/plan.md',
          reason: 'readFile must pass the path itself, not a map');
    });

    test('writeFile sends the {path, content} pair MainActivity parses',
        () async {
      final ws = PlatformWorkspace();

      await ws.writeFile('notes/plan.md', 'supper plan');

      expect(calls.single.method, 'writeFile');
      expect(calls.single.arguments, <String, dynamic>{
        'path': 'notes/plan.md',
        'content': 'supper plan',
      });
      expect(files['notes/plan.md'], 'supper plan');
    });

    test('deleteFile takes the raw path and decodes the bool outcome',
        () async {
      final ws = PlatformWorkspace();

      expect(await ws.deleteFile('notes/plan.md'), isTrue);
      expect(await ws.deleteFile('notes/plan.md'), isFalse,
          reason: 'second delete of the same path must report false');

      expect(calls, hasLength(2));
      expect(calls.first.method, 'deleteFile');
      expect(calls.first.arguments, 'notes/plan.md');
    });

    test('exists is answered through readFile', () async {
      final ws = PlatformWorkspace();

      expect(await ws.exists('notes/plan.md'), isTrue);
      expect(await ws.exists('missing.txt'), isFalse);

      expect(calls.map((c) => c.method).toList(), everyElement('readFile'));
    });

    test('listFiles takes the raw prefix, filters and sorts the result',
        () async {
      final ws = PlatformWorkspace();

      expect(await ws.listFiles('notes'), ['notes/plan.md']);
      final all = await ws.listFiles();
      expect(all, ['dinner-list.txt', 'notes/plan.md'],
          reason: 'unfiltered listings must come back sorted');

      expect(calls, hasLength(2));
      expect(calls.first.method, 'listFiles');
      expect(calls.first.arguments, 'notes');
      expect(calls.last.arguments, '',
          reason: 'the default prefix must be the empty string');
    });

    test('searchFiles scans names and contents, case-insensitively, and '
        'skips the channel for an empty query', () async {
      final ws = PlatformWorkspace();

      // Empty query: no traffic at all, straight to the empty result.
      expect(await ws.searchFiles(''), isEmpty);
      expect(calls, isEmpty);

      // 'DINNER' matches one file by name and the other by content.
      expect(await ws.searchFiles('DINNER'),
          ['dinner-list.txt', 'notes/plan.md']);
      expect(calls.map((c) => c.method).toList(),
          containsAll(<String>['listFiles', 'readFile']));
    });
  });
}
