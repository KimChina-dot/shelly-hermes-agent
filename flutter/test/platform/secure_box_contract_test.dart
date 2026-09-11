// PHASE 20 (plan P13): platform-channel contract tests for the
// `dev.shelly/secure_store` bridge (`lib/platform/secure_box.dart`,
// native side MainActivity.kt -> SecureStore.kt, AndroidKeyStore AES/GCM).
//
// Two contracts per the plan:
//  (a) non-Android host: createSecureBox() must hand out the
//      SharedPreferences-backed box — a mock channel handler records the
//      'dev.shelly/secure_store' channel and asserts ZERO traffic while
//      values round-trip under the `shelly.secure.` prefix.
//  (b) wire contract: the channel-backed box (exposed via the
//      debugChannelSecureBox test hook) speaks the exact shapes the native
//      SecureStore.kt handler parses — read/delete take the RAW key string
//      (not a map), write takes {'key', 'value'}, and String? results
//      decode (null = missing key).
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/platform/platform_workspace.dart';
import 'package:shelly_hermes/platform/secure_box.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dev.shelly/secure_store');
  final calls = <MethodCall>[];
  // In-memory model of the AndroidKeyStore entries the mock native side
  // holds; read/write/delete operate on it so return decoding is exercised
  // against realistic values.
  final keystore = <String, String>{};

  Future<Object?>? handler(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'read':
        return keystore[call.arguments as String];
      case 'write':
        final args = call.arguments as Map;
        keystore[args['key'] as String] = args['value'] as String;
        return null;
      case 'delete':
        keystore.remove(call.arguments as String);
        return null;
    }
    return null;
  }

  setUp(() {
    calls.clear();
    keystore.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('non-Android host (a): prefs fallback, zero channel traffic', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('premise: this runner is not the Android host', () {
      expect(isAndroidHost, isFalse,
          reason: 'secure_store host-guard tests require a non-Android host');
    });

    test('createSecureBox never touches the secure_store channel', () async {
      final box = createSecureBox()!;

      await box.write('model.apiKey', 'sk-test-123');
      expect(await box.read('model.apiKey'), 'sk-test-123');
      await box.delete('model.apiKey');
      expect(await box.read('model.apiKey'), isNull);

      expect(calls, isEmpty,
          reason: 'off Android, secure storage must not touch the channel');
    });

    test('values land under the shelly.secure. prefix; empty write clears',
        () async {
      final box = createSecureBox()!;

      await box.write('apiKey', 'v1');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('shelly.secure.apiKey'), 'v1');

      // Writing the empty string is the documented "remove" semantic.
      await box.write('apiKey', '');
      expect(prefs.getString('shelly.secure.apiKey'), isNull);
      expect(await box.read('apiKey'), isNull);
    });
  });

  group('wire contract (b): channel-backed box vs mock handler', () {
    test('read sends the raw key and decodes the stored value or null',
        () async {
      final box = debugChannelSecureBox();
      keystore['apiKey'] = 'sk-live-42';

      expect(await box.read('apiKey'), 'sk-live-42');
      expect(await box.read('missing'), isNull);

      expect(calls, hasLength(2));
      expect(calls[0].method, 'read');
      expect(calls[0].arguments, 'apiKey',
          reason: 'read must pass the key itself, not a map');
      expect(calls[1].arguments, 'missing');
    });

    test('write sends the {key, value} map SecureStore.kt parses', () async {
      final box = debugChannelSecureBox();

      await box.write('apiKey', 'sk-live-42');

      expect(calls.single.method, 'write');
      expect(calls.single.arguments,
          <String, dynamic>{'key': 'apiKey', 'value': 'sk-live-42'});
      expect(keystore['apiKey'], 'sk-live-42');
    });

    test('delete sends the raw key', () async {
      final box = debugChannelSecureBox();
      keystore['apiKey'] = 'stale';

      await box.delete('apiKey');

      expect(calls.single.method, 'delete');
      expect(calls.single.arguments, 'apiKey');
      expect(keystore, isNot(contains('apiKey')));
    });
  });
}
