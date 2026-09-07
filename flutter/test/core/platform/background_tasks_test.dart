import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/platform/background_tasks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dev.shelly/bg_tasks');
  final List<MethodCall> calls = [];
  bool pendingTakeValue = false;

  Future<Object?>? handler(MethodCall call) async {
    calls.add(call);
    if (call.method == 'takePendingCatchup') {
      final value = pendingTakeValue;
      pendingTakeValue = false;
      return value;
    }
    return null;
  }

  setUp(() {
    calls.clear();
    pendingTakeValue = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('BackgroundTaskBridge', () {
    test('scheduleWorkChecks sends the interval on the schedule method',
        () async {
      final bridge = BackgroundTaskBridge();
      await bridge.scheduleWorkChecks(intervalMinutes: 15);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'schedule');
      expect(calls.single.arguments, {
        'intervalMinutes': 15,
      });
    });

    test('pushState sends the task list for the native worker', () async {
      final bridge = BackgroundTaskBridge();
      await bridge.pushState([
        {'id': 't1', 'at': 1727300000000},
        {'id': 't2', 'at': 1727303600000},
      ]);
      expect(calls.single.method, 'pushState');
      final args = calls.single.arguments as Map;
      expect((args['tasks'] as List), hasLength(2));
    });

    test('cancel invokes the cancel method with no arguments', () async {
      final bridge = BackgroundTaskBridge();
      await bridge.cancel();
      expect(calls.single.method, 'cancel');
    });

    test('catchup event routes to the registered callback', () async {
      final bridge = BackgroundTaskBridge();
      var fired = 0;
      bridge.handlePendingCatchup(() => fired++);
      // Simulate the native side pushing a catchup event.
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(const MethodCall('catchup')),
        (_) {},
      );
      expect(fired, 1);
      bridge.dispose();
    });

    test('pending catch-up cached before registration is drained', () async {
      pendingTakeValue = true;
      final bridge = BackgroundTaskBridge();
      var fired = 0;
      bridge.handlePendingCatchup(() => fired++);
      // The drain is asynchronous; allow the microtask to land.
      await Future<void>.delayed(Duration.zero);
      expect(fired, 1);
      bridge.dispose();
    });

    test('missing native handler degrades to a no-op', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      final bridge = BackgroundTaskBridge();
      var fired = 0;
      // None of these may throw on hosts without the native side.
      await bridge.scheduleWorkChecks(intervalMinutes: 15);
      await bridge.pushState(const []);
      await bridge.cancel();
      bridge.handlePendingCatchup(() => fired++);
      await Future<void>.delayed(Duration.zero);
      expect(fired, 0);
      bridge.dispose();
    });

    test('dispose detaches the handler', () async {
      final bridge = BackgroundTaskBridge();
      var fired = 0;
      bridge.handlePendingCatchup(() => fired++);
      bridge.dispose();
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(const MethodCall('catchup')),
        (_) {},
      );
      expect(fired, 0);
    });
  });
}
