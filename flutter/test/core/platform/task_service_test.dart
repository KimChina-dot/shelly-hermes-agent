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
// the assertion. The Android invoke path itself needs a device/emulator
// (dart:io Platform is not overridable), so these tests pin the contract
// that actually runs on CI.
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
}
