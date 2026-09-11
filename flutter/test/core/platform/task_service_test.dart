// PHASE 15 safety net (TEST_COVERAGE_MAP §3): direct tests for the
// task_service platform thin-layer. The audit found no direct references
// in test/ — the service was only touched indirectly through the session
// controller.
//
// Host contract: TaskService guards every call with `isAndroidHost`
// (dart:io Platform.isAndroid), so on every non-Android host — including
// this test VM and CI — all three entry points must be silent no-ops that
// never touch the 'dev.shelly/task_service' method channel and never
// throw. A mock channel handler records any traffic; zero recordings is
// the assertion.
//
// PHASE 20 (plan P13) adds the wire-contract half: with the
// `debugUseChannel` test hook forcing the guarded path on, a mock handler
// pins the method names MainActivity.kt must answer (start / stop /
// requestNotificationPermission, all argument-less) and the swallowed
// PlatformException semantics for each.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/platform/platform_workspace.dart';
import 'package:shelly_hermes/platform/task_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dev.shelly/task_service');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('start/stop/permission are silent no-ops off the Android host',
      () async {
    // Guard the test's own premise: these assertions are about the
    // non-Android branch. On an Android-targeted runner this would need
    // a different expectation.
    expect(isAndroidHost, isFalse,
        reason: 'task_service host-guard tests require a non-Android host');

    await TaskService.start();
    await TaskService.stop();
    await TaskService.requestNotificationPermission();

    expect(calls, isEmpty,
        reason: 'off Android, TaskService must not touch the method channel');
  });

  test('repeated start/stop cycles stay silent and never throw', () async {
    await TaskService.start();
    await TaskService.start();
    await TaskService.stop();
    await TaskService.requestNotificationPermission();
    await TaskService.stop();

    expect(calls, isEmpty);
  });

  group('wire contract (mock handler, channel forced on) — PHASE 20', () {
    setUp(() {
      calls.clear();
      TaskService.debugUseChannel = true;
    });

    tearDown(() {
      TaskService.debugUseChannel = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('start/stop/requestNotificationPermission use the documented '
        'argument-less methods', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });

      await TaskService.start();
      await TaskService.stop();
      await TaskService.requestNotificationPermission();

      expect(calls.map((c) => c.method).toList(),
          ['start', 'stop', 'requestNotificationPermission']);
      for (final call in calls) {
        expect(call.arguments, isNull,
            reason: '${call.method} must not carry arguments');
      }
    });

    test('a failing native handler never breaks the caller '
        '(PlatformException is swallowed per entry point)', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        throw PlatformException(
            code: 'task_service', message: 'native refused ${call.method}');
      });

      // None of these may throw: start survives a missing notification
      // permission, stop survives "already stopped", and the permission
      // prompt survives being unavailable.
      await TaskService.start();
      await TaskService.stop();
      await TaskService.requestNotificationPermission();

      expect(calls, hasLength(3),
          reason: 'every entry point must still reach the native side once');
    });
  });
}
