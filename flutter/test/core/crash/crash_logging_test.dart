import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shelly_hermes/core/crash/crash_log_store.dart';

/// A store whose record call explodes synchronously, used to prove the
/// installed handlers never let recording failures escape.
class _ExplodingStore extends CrashLogStore {
  _ExplodingStore() : super(_emptyPrefs);

  static final _emptyPrefs = _NullPrefs();

  @override
  Future<void> record({
    required String context,
    required Object error,
    StackTrace? stack,
    DateTime? at,
  }) =>
      throw StateError('recorder broke');
}

/// Stand-in preferences for [_ExplodingStore]; never touched.
class _NullPrefs implements SharedPreferences {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FlutterExceptionHandler? originalFlutterHandler;
  late bool Function(Object error, StackTrace stackTrace)?
      originalPlatformHandler;
  final detaches = <void Function()>[];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    originalFlutterHandler = FlutterError.onError;
    originalPlatformHandler = PlatformDispatcher.instance.onError;
  });

  tearDown(() {
    for (final detach in detaches) {
      detach();
    }
    detaches.clear();
    // Belt and braces: restore what was captured before the test ran so
    // other suites are never polluted by the handlers installed here.
    FlutterError.onError = originalFlutterHandler;
    PlatformDispatcher.instance.onError = originalPlatformHandler;
  });

  Future<CrashLogStore> newStore() async =>
      CrashLogStore(await SharedPreferences.getInstance());

  test('captures a FlutterError into the store', () async {
    final store = await newStore();
    detaches.add(installCrashLogging(store));

    FlutterError.onError!(
      FlutterErrorDetails(
        exception: Exception('ui broke'),
        stack: StackTrace.current,
        library: 'test',
      ),
    );
    await pumpEventQueue();

    final entries = store.loadEntries();
    expect(entries, hasLength(1));
    expect(entries.single.context, 'flutter');
    expect(entries.single.error, contains('ui broke'));
    expect(entries.single.stack, isNotEmpty);
  });

  test('chains the previously installed Flutter handler', () async {
    final seen = <FlutterErrorDetails>[];
    FlutterError.onError = (details) => seen.add(details);

    final store = await newStore();
    detaches.add(installCrashLogging(store));

    FlutterError.onError!(
      FlutterErrorDetails(exception: Exception('chained'), library: 'test'),
    );
    await pumpEventQueue();

    expect(seen, hasLength(1));
    expect(seen.single.exception.toString(), contains('chained'));
    expect(store.loadEntries(), hasLength(1));
  });

  test('captures platform dispatch errors with the platform context',
      () async {
    final store = await newStore();
    detaches.add(installCrashLogging(store));

    final handled = PlatformDispatcher.instance.onError!(
      Exception('platform broke'),
      StackTrace.current,
    );
    await pumpEventQueue();

    expect(handled, isTrue);
    final entries = store.loadEntries();
    expect(entries, hasLength(1));
    expect(entries.single.context, 'platform');
    expect(entries.single.error, contains('platform broke'));
  });

  test('platform handler preserves the previous handler verdict', () async {
    PlatformDispatcher.instance.onError = (error, stackTrace) => false;
    final store = await newStore();
    detaches.add(installCrashLogging(store));

    final handled = PlatformDispatcher.instance.onError!(
      Exception('verdict'),
      StackTrace.current,
    );
    await pumpEventQueue();

    expect(handled, isFalse);
    expect(store.loadEntries(), hasLength(1));
  });

  test('double install is a guarded no-op', () async {
    final store = await newStore();
    detaches.add(installCrashLogging(store));
    final installed = FlutterError.onError;

    final secondDetach = installCrashLogging(store);
    expect(FlutterError.onError, same(installed));
    expect(PlatformDispatcher.instance.onError, isNotNull);

    // The skipped install must not clobber the active handlers either.
    secondDetach();
    expect(FlutterError.onError, same(installed));
  });

  test('detach restores the original handlers', () async {
    var flutterCalls = 0;
    var platformCalled = false;
    FlutterError.onError = (details) => flutterCalls++;
    PlatformDispatcher.instance.onError = (error, stackTrace) {
      platformCalled = true;
      return false;
    };

    final detach = installCrashLogging(await newStore());

    // While installed, the recording handler sits in the chain.
    FlutterError.onError!(
      FlutterErrorDetails(exception: Exception('x'), library: 'test'),
    );
    await pumpEventQueue();
    expect(flutterCalls, 1);

    detach();
    // The original closures are back: invoking them flips the flags.
    FlutterError.onError!(
      FlutterErrorDetails(exception: Exception('y'), library: 'test'),
    );
    expect(flutterCalls, 2);
    final verdict =
        PlatformDispatcher.instance.onError!(Object(), StackTrace.current);
    expect(verdict, isFalse);
    expect(platformCalled, isTrue);
  });

  test('a recording failure never throws out of the handlers', () async {
    var chained = false;
    FlutterError.onError = (details) => chained = true;

    detaches.add(installCrashLogging(_ExplodingStore()));

    expect(
      () => FlutterError.onError!(
        FlutterErrorDetails(exception: Exception('e'), library: 'test'),
      ),
      returnsNormally,
    );
    expect(chained, isTrue);
  });
}
