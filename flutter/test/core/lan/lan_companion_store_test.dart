import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelly_hermes/state/lan_companion.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LanCompanionStore', () {
    test('enabled defaults to false and round-trips', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LanCompanionStore(await SharedPreferences.getInstance());
      expect(store.loadEnabled(), isFalse);
      await store.setEnabled(true);
      expect(store.loadEnabled(), isTrue);
      // Survives a fresh store over the same persisted prefs.
      final reborn =
          LanCompanionStore(await SharedPreferences.getInstance());
      expect(reborn.loadEnabled(), isTrue);
    });

    test('token is generated once (8 alphanumerics) and then stable',
        () async {
      SharedPreferences.setMockInitialValues({});
      final store = LanCompanionStore(await SharedPreferences.getInstance());
      final token = await store.loadToken();
      expect(token, hasLength(8));
      expect(RegExp(r'^[A-Za-z0-9]{8}$').hasMatch(token), isTrue);
      expect(await store.loadToken(), token);
      final reborn =
          LanCompanionStore(await SharedPreferences.getInstance());
      expect(await reborn.loadToken(), token);
    });

    test('generateToken honours length and alphabet', () {
      final token = LanCompanionStore.generateToken(length: 12, random: Random(1));
      expect(token, hasLength(12));
      expect(RegExp(r'^[A-Za-z0-9]{12}$').hasMatch(token), isTrue);
    });
  });

  test('lanIPv4Addresses never throws and lists no loopback', () async {
    final addresses = await lanIPv4Addresses();
    expect(addresses, isA<List<String>>());
    for (final address in addresses) {
      expect(address, isNot('127.0.0.1'));
    }
  });
}
