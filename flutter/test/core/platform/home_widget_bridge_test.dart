import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/platform/home_widget_bridge.dart';

/// Platform-channel tests for the Android home-screen widget bridge
/// (PHASE 42). The native side is mocked at the binary-messenger level:
/// outgoing calls (pushUpdate / takePendingAction) are recorded by a mock
/// handler, incoming `action` events are simulated by delivering a platform
/// message on the channel.
void main() {
  const channel = MethodChannel('dev.shelly/hermes_widget');

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    // Fresh channel per test: no stale mock from a previous case.
    TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// Delivers a platform -> Dart method call on the widget channel and
  /// waits until the registered Dart handler has finished.
  Future<void> simulateIncoming(MethodCall call) async {
    final done = Completer<void>();
    await TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(call),
      (ByteData? _) => done.complete(),
    );
    await done.future;
  }

  /// Lets the unawaited `takePendingAction` drain finish.
  Future<void> flushMicrotasks() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  test('routes incoming action events to the registered callback', () async {
    final actions = <String>[];
    final bridge = HomeWidgetBridge()..register(actions.add);
    await flushMicrotasks();

    await simulateIncoming(const MethodCall('action', 'open'));
    expect(actions, ['open']);

    // Non-action methods and empty payloads are ignored.
    await simulateIncoming(const MethodCall('ignore_me', 'open'));
    await simulateIncoming(const MethodCall('action', ''));
    expect(actions, ['open']);

    bridge.dispose();
    // After dispose the handler is detached: no further deliveries.
    await simulateIncoming(const MethodCall('action', 'open'));
    expect(actions, ['open']);
  });

  test('pushUpdate invokes the channel with the snapshot payload', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });

    final bridge = HomeWidgetBridge();
    await bridge.pushUpdate(
      lastConversationTitle: '周三晚饭计划',
      conversationCount: 7,
    );

    expect(calls, hasLength(1));
    expect(calls.single.method, 'pushUpdate');
    expect(calls.single.arguments, <String, dynamic>{
      'lastConversationTitle': '周三晚饭计划',
      'conversationCount': 7,
    });

    bridge.dispose();
  });

  test('drains an action cached before the handler registered', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'takePendingAction') return 'open';
      return null;
    });

    final actions = <String>[];
    final bridge = HomeWidgetBridge()..register(actions.add);
    await flushMicrotasks();

    expect(calls.single.method, 'takePendingAction');
    expect(actions, ['open']);

    bridge.dispose();
  });

  test('stays a no-op when the platform channel is missing', () async {
    // No mock handler: every invokeMethod completes with
    // MissingPluginException, which the bridge must swallow (this test
    // fails via unhandled async errors if it does not).
    final actions = <String>[];
    final bridge = HomeWidgetBridge()..register(actions.add);

    await bridge.pushUpdate(
      lastConversationTitle: '随便一条',
      conversationCount: 3,
    );
    await flushMicrotasks();

    expect(actions, isEmpty);
    bridge.dispose();
  });

  test('pushUpdate never breaks the caller when the native side fails '
      '(PHASE 20: the catch-all swallow is contractual)', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      throw PlatformException(
          code: 'hermes_widget', message: 'repaint refused');
    });

    final bridge = HomeWidgetBridge();
    await bridge.pushUpdate(
      lastConversationTitle: '随便一条',
      conversationCount: 3,
    );

    expect(calls, hasLength(1),
        reason: 'pushUpdate must still reach the native side exactly once');
    bridge.dispose();
  });

  test('does not deliver a cached action after dispose', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'takePendingAction') return 'open';
      return null;
    });

    final actions = <String>[];
    final bridge = HomeWidgetBridge()..register(actions.add);
    // Callback detached before the unawaited drain completes.
    bridge.dispose();
    await flushMicrotasks();

    expect(actions, isEmpty);
  });
}
