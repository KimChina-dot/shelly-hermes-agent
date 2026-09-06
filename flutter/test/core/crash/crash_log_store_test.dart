import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shelly_hermes/core/crash/crash_log_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CrashLogStore persistence', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('record round-trips through SharedPreferences', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = CrashLogStore(prefs);

      final at = DateTime(2026, 9, 6, 8, 30);
      await store.record(
        context: 'flutter',
        error: StateError('boom'),
        stack: StackTrace.fromString('frame a\nframe b'),
        at: at,
      );

      // A fresh store over the same backing prefs must see the entry.
      final entries =
          CrashLogStore(await SharedPreferences.getInstance()).loadEntries();
      expect(entries, hasLength(1));
      expect(entries.single.context, 'flutter');
      expect(entries.single.error, 'Bad state: boom');
      expect(entries.single.stack, 'frame a\nframe b');
      expect(entries.single.at, at);

      final raw = jsonDecode(prefs.getString('shelly.crash.logs')!)
          as List<dynamic>;
      final json = raw.single as Map<String, dynamic>;
      expect(json['at'], at.toIso8601String());
      expect(json['context'], 'flutter');
      expect(json['error'], 'Bad state: boom');
      expect(json['stack'], 'frame a\nframe b');
    });

    test('entries come back newest-first', () async {
      final store =
          CrashLogStore(await SharedPreferences.getInstance());
      await store.record(
          context: 'flutter',
          error: 'first',
          at: DateTime(2026, 9, 1, 10));
      await store.record(
          context: 'platform',
          error: 'second',
          at: DateTime(2026, 9, 2, 10));
      await store.record(
          context: 'flutter',
          error: 'third',
          at: DateTime(2026, 9, 3, 10));

      final entries = store.loadEntries();
      expect(entries.map((e) => e.error).toList(), ['third', 'second', 'first']);
      expect(entries[1].context, 'platform');
    });

    test('cap 50: the oldest entries are dropped, newest kept', () async {
      final store =
          CrashLogStore(await SharedPreferences.getInstance());
      for (var i = 1; i <= 55; i++) {
        await store.record(
          context: 'flutter',
          error: 'crash-$i',
          at: DateTime(2026, 1, 1).add(Duration(minutes: i)),
        );
      }
      final entries = store.loadEntries();
      expect(entries, hasLength(CrashLogStore.maxEntries));
      expect(entries.first.error, 'crash-55');
      expect(entries.last.error, 'crash-6');
    });

    test('stacks longer than 2000 chars are truncated', () async {
      final store =
          CrashLogStore(await SharedPreferences.getInstance());
      final longStack = StackTrace.fromString('f\n${'x' * 3000}');
      await store.record(
        context: 'platform',
        error: 'overflow',
        stack: longStack,
        at: DateTime(2026, 9, 6),
      );
      final entries = store.loadEntries();
      expect(entries.single.stack.length, CrashLogStore.maxStackLength);
      expect(entries.single.stack.startsWith('f\n'), isTrue);
    });

    test('missing or corrupt payloads fall back to an empty list', () async {
      final prefs = await SharedPreferences.getInstance();
      expect(CrashLogStore(prefs).loadEntries(), isEmpty);

      await prefs.setString('shelly.crash.logs', 'not-json{');
      expect(CrashLogStore(prefs).loadEntries(), isEmpty);
    });

    test('clear removes every stored entry', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = CrashLogStore(prefs);
      await store.record(
          context: 'flutter', error: 'one', at: DateTime(2026, 9, 6));
      await store.record(
          context: 'flutter', error: 'two', at: DateTime(2026, 9, 6));
      await store.clear();
      expect(CrashLogStore(prefs).loadEntries(), isEmpty);
    });
  });
}
