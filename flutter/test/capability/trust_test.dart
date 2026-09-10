import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shelly_hermes/capability/trust/trust_store.dart';

void main() {
  late TrustStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = TrustStore(await SharedPreferences.getInstance());
  });

  group('TrustStore', () {
    test('record updates uses and success rate', () {
      store.record('files', ok: true);
      store.record('files', ok: true);
      store.record('files', ok: false);

      final score = store.scoreFor('files');
      expect(score.uses, 3);
      expect(score.successes, 2);
      expect(score.failures, 1);
      expect(score.successRate, closeTo(2 / 3, 0.001));
    });

    test('unknown capability returns a zero score', () {
      final score = store.scoreFor('不存在');
      expect(score.uses, 0);
      expect(score.successRate, 0);
    });

    test('persistence round-trips across store instances', () async {
      store.record('files', ok: true);
      final restored = TrustStore(await SharedPreferences.getInstance());
      expect(restored.scoreFor('files').uses, 1);
      expect(restored.scoreFor('files').successes, 1);
    });

    test('corrupt payload falls back to empty without throwing', () async {
      SharedPreferences.setMockInitialValues({
        'shelly.capability.trust': '{{{not json',
      });
      final restored = TrustStore(await SharedPreferences.getInstance());
      expect(restored.all(), isEmpty);
      // And recording still works afterwards.
      restored.record('files', ok: true);
      expect(restored.scoreFor('files').uses, 1);
    });

    test('delete removes one capability and keeps others', () {
      store.record('a', ok: true);
      store.record('b', ok: true);
      store.delete('a');
      expect(store.scoreFor('a').uses, 0);
      expect(store.scoreFor('b').uses, 1);
    });

    test('cap keeps at most 200 tracked capabilities', () {
      for (var i = 0; i < 210; i++) {
        store.record('cap$i', ok: true);
      }
      expect(store.all().length, TrustStore.maxEntries);
      expect(store.scoreFor('cap0').uses, 0); // 最先见的被裁剪
      expect(store.scoreFor('cap209').uses, 1);
    });
  });
}
