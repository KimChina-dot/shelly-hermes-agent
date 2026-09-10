// Tests for the interactive bridge dashboard. Everything is driven through
// an injectable recording sink + an injectable stdin line stream, and the
// wrapped BridgeServer is a fake subclass, so no real terminal or HTTP
// server is used.
//
// PHASE 15 determinism: the repaint loop's ticker and deferred-repaint
// timers are created through an injectable [BridgeTimerFactory] (default:
// real timers, zero behavior change), and every test injects a fake factory
// plus a scripted clock. No assertion in this file depends on wall-clock
// time — timers fire only when the test fires them.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/mcp/bridge_dashboard.dart';
import 'package:shelly_hermes/core/mcp/bridge_server.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// StringSink that records every write so tests can inspect individual
/// frames and dump output.
class _RecordingSink implements StringSink {
  final List<String> writes = <String>[];

  String get text => writes.join();
  String get first => writes.first;
  String get last => writes.last;

  @override
  void write(Object? obj) => writes.add('$obj');

  @override
  void writeln([Object? obj = '']) => writes.add('$obj\n');

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      writes.add(objects.join(separator));

  @override
  void writeCharCode(int charCode) =>
      writes.add(String.fromCharCode(charCode));
}

/// Mutable clock: the dashboard reads it only through the injected
/// `clock` callback, so tests advance time explicitly.
class _ScriptedClock {
  DateTime now = DateTime(2026, 9, 10, 12, 0, 0);

  DateTime call() => now;

  void advance(Duration by) => now = now.add(by);
}

/// Fake timer seam: records every timer the dashboard schedules and lets
/// tests fire (or cancel) them by hand. `pending` one-shots are the not-yet
/// fired, not-cancelled ones — what the dashboard currently holds.
class _FakeTimer implements BridgeTimer {
  _FakeTimer.oneShot(this.delay, this.onTick) : interval = null;
  _FakeTimer.periodic(this.interval, this.onTick) : delay = null;

  final Duration? delay;
  final Duration? interval;
  final void Function() onTick;

  bool canceled = false;
  bool fired = false;

  bool get isPending => !canceled && !fired;

  @override
  void cancel() {
    canceled = true;
  }

  void fire() {
    if (canceled || fired) {
      throw StateError('timer is no longer runnable');
    }
    fired = interval == null;
    onTick();
  }
}

class _FakeTimerFactory implements BridgeTimerFactory {
  final List<_FakeTimer> created = <_FakeTimer>[];

  List<_FakeTimer> get periodics =>
      created.where((t) => t.interval != null).toList();
  List<_FakeTimer> get oneShots =>
      created.where((t) => t.interval == null).toList();
  List<_FakeTimer> get pendingOneShots =>
      oneShots.where((t) => t.isPending).toList();

  @override
  BridgeTimer periodic(Duration interval, void Function() onTick) {
    final timer = _FakeTimer.periodic(interval, onTick);
    created.add(timer);
    return timer;
  }

  @override
  BridgeTimer oneShot(Duration delay, void Function() onTick) {
    final timer = _FakeTimer.oneShot(delay, onTick);
    created.add(timer);
    return timer;
  }
}

/// BridgeServer fake: never starts anything, reports a scripted health
/// payload and counts stop() calls.
class _FakeBridgeServer extends BridgeServer {
  _FakeBridgeServer() : super(config: const BridgeConfig(servers: []));

  Map<String, dynamic> health = const <String, dynamic>{
    'ok': true,
    'servers': <Map<String, dynamic>>[],
  };

  int stopCount = 0;

  @override
  int get port => 8766;

  @override
  bool get isRunning => stopCount == 0;

  @override
  Map<String, dynamic> healthPayload() => health;

  @override
  Future<void> stop() async {
    stopCount += 1;
  }
}

Map<String, dynamic> _health(List<Map<String, dynamic>> servers) =>
    <String, dynamic>{'ok': true, 'servers': servers};

Map<String, dynamic> _serverEntry(
  String id, {
  String? name,
  bool alive = false,
  int toolCount = 0,
}) =>
    <String, dynamic>{
      'id': id,
      'name': name ?? id,
      'alive': alive,
      'toolCount': toolCount,
    };

/// Flushes stream/microtask delivery without any wall-clock dependency:
/// no real timer exists in these tests, so the duration is irrelevant.
Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 10));

class _Harness {
  _Harness(this.dashboard, this.input, this.clock, this.timers);

  final BridgeDashboard dashboard;
  final StreamController<String> input;
  final _ScriptedClock clock;
  final _FakeTimerFactory timers;
}

_Harness _dashboard(
  _FakeBridgeServer server,
  _RecordingSink out,
  StreamController<String> input, {
  Duration interval = const Duration(milliseconds: 500),
}) {
  final clock = _ScriptedClock();
  final timers = _FakeTimerFactory();
  final dashboard = BridgeDashboard(
    server: server,
    token: 'secret-token',
    output: out,
    inputLines: input.stream,
    refreshInterval: interval,
    lanAddressProvider: () async => const <String>['http://10.0.0.5:8766'],
    clock: clock.call,
    timerFactory: timers,
  );
  return _Harness(dashboard, input, clock, timers);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  test('render shows bridge url, lan addresses, server lines and masks the token',
      () async {
    final server = _FakeBridgeServer()
      ..health = _health([
        _serverEntry('filesys', name: '文件系统', alive: true, toolCount: 7),
        _serverEntry('git', name: 'Git MCP', alive: false),
      ]);
    final out = _RecordingSink();
    final input = StreamController<String>();
    final h = _dashboard(server, out, input);
    final done = h.dashboard.run();
    await _pump();

    final frame = out.first;
    expect(frame, contains('桥接地址: http://localhost:8766'));
    expect(frame, contains('http://10.0.0.5:8766'));
    expect(frame, contains('[+] filesys (文件系统)'));
    expect(frame, contains('运行中'));
    expect(frame, contains('工具 7'));
    expect(frame, contains('重启 0 次'));
    expect(frame, contains('[x] git (Git MCP)'));
    expect(frame, contains('已离线'));
    expect(frame, isNot(contains('secret-token')));
    expect(frame, contains('配对令牌: ************ (按 t 显示)'));
    // The periodic ticker exists but never fired: exactly one paint.
    expect(h.dashboard.repaintCount, 1);
    expect(h.timers.periodics, hasLength(1));

    input.add('q');
    await done;
    expect(server.stopCount, 1);
    expect(out.text, contains('桥接服务已停止'));
  });

  test('t toggles token masking in both directions', () async {
    final server = _FakeBridgeServer();
    final out = _RecordingSink();
    final input = StreamController<String>();
    final h = _dashboard(server, out, input);
    final done = h.dashboard.run();
    await _pump();
    expect(out.last, isNot(contains('secret-token')));

    input.add('t');
    await _pump();
    expect(out.last, contains('secret-token'));
    expect(out.last, contains('(按 t 隐藏)'));
    expect(out.last, isNot(contains('************')));

    input.add('t');
    await _pump();
    expect(out.last, contains('************'));
    expect(out.last, isNot(contains('secret-token')));
    expect(h.dashboard.repaintCount, 3);

    input.add('q');
    await done;
  });

  test('scripted call log entries appear after a forced repaint', () async {
    final server = _FakeBridgeServer()
      ..health = _health([_serverEntry('filesys', alive: true, toolCount: 1)]);
    final out = _RecordingSink();
    final input = StreamController<String>();
    final h = _dashboard(server, out, input);
    final done = h.dashboard.run();
    await _pump();

    h.dashboard.callLog.record(
      server: 'filesys',
      tool: 'read_file',
      durationMs: 123,
      ok: true,
      time: DateTime(2026, 9, 8, 15, 30, 5),
    );
    h.dashboard.recordCall(
      server: 'git',
      tool: 'status',
      durationMs: 45,
      ok: false,
      error: 'boom',
    );
    expect(h.dashboard.callLog.length, 2);

    input.add('r');
    await _pump();
    final frame = out.last;
    expect(frame, contains('filesys.read_file'));
    expect(frame, contains('123 ms'));
    expect(frame, contains('OK'));
    expect(frame, contains('git.status'));
    expect(frame, contains('45 ms'));
    expect(frame, contains('失败: boom'));

    input.add('q');
    await done;
  });

  test('l dumps the full call log, beyond the last 10 shown on screen',
      () async {
    final server = _FakeBridgeServer();
    final out = _RecordingSink();
    final input = StreamController<String>();
    final h = _dashboard(server, out, input);
    final done = h.dashboard.run();
    await _pump();

    for (var i = 1; i <= 12; i++) {
      h.dashboard.callLog.record(
        server: 'filesys',
        tool: 't${i.toString().padLeft(2, '0')}',
        durationMs: i,
        ok: true,
        time: DateTime(2026, 9, 8, 15, 30, i),
      );
    }

    input.add('l');
    await _pump();
    // The dump is written as separate lines; check the accumulated output.
    expect(out.text, contains('=== 完整调用日志 (12 条) ==='));
    expect(out.text, contains('t01')); // oldest — never shown in the frame
    expect(out.text, contains('t12'));

    input.add('r');
    await _pump();
    final frame = out.last;
    expect(frame, contains('t03')); // 10 most recent start at t03
    expect(frame, contains('t12'));
    expect(frame, isNot(contains('t01')));
    expect(frame, isNot(contains('t02')));

    input.add('q');
    await done;
  });

  test('restart counter increments when a live server goes down, then persists',
      () async {
    final server = _FakeBridgeServer()
      ..health = _health([_serverEntry('filesys', alive: true, toolCount: 2)]);
    final out = _RecordingSink();
    final input = StreamController<String>();
    final h = _dashboard(server, out, input);
    final done = h.dashboard.run();
    await _pump();

    server.health =
        _health([_serverEntry('filesys', alive: false, toolCount: 0)]);
    input.add('r');
    await _pump();
    expect(out.last, contains('重启中'));
    expect(out.last, contains('重启 1 次'));

    server.health =
        _health([_serverEntry('filesys', alive: true, toolCount: 2)]);
    input.add('r');
    await _pump();
    expect(out.last, contains('运行中'));
    expect(out.last, contains('重启 1 次'));

    input.add('q');
    await done;
  });

  test('q stops the server gracefully and ends the loop', () async {
    final server = _FakeBridgeServer();
    final out = _RecordingSink();
    final input = StreamController<String>();
    final h = _dashboard(server, out, input);
    final done = h.dashboard.run();
    await _pump();

    input.add('q');
    await done;
    expect(server.stopCount, 1);
    expect(out.text, contains('正在停止桥接服务…'));
    // Shutdown cancels both the ticker and any pending deferred repaint.
    expect(h.timers.periodics.single.canceled, isTrue);
    for (final timer in h.timers.pendingOneShots) {
      expect(timer.canceled, isTrue);
    }
  });

  test('closing the input stream quits and stops the server', () async {
    final server = _FakeBridgeServer();
    final out = _RecordingSink();
    final input = StreamController<String>();
    final h = _dashboard(server, out, input);
    final done = h.dashboard.run();
    await _pump();

    await input.close();
    await done;
    expect(server.stopCount, 1);
    expect(h.timers.periodics.single.canceled, isTrue);
  });

  test('repaint loop is throttled to the refresh interval (at most 2x/sec)',
      () async {
    final server = _FakeBridgeServer()
      ..health = _health([_serverEntry('filesys', alive: true, toolCount: 3)]);
    final out = _RecordingSink();
    final input = StreamController<String>();
    final h = _dashboard(server, out, input);
    final done = h.dashboard.run();
    await _pump();
    expect(h.dashboard.repaintCount, 1);

    // A burst of non-forced refresh requests must not repaint immediately…
    for (var i = 0; i < 10; i++) {
      input.add('x$i');
    }
    await _pump();
    expect(h.dashboard.repaintCount, 1);

    // …and must coalesce into exactly one deferred repaint at the interval
    // boundary. A second burst while it is pending schedules nothing new.
    input.add('again');
    await _pump();
    expect(h.timers.pendingOneShots, hasLength(1));
    expect(h.dashboard.repaintCount, 1);

    // Firing the deferred repaint paints once — the whole burst collapses.
    h.clock.advance(const Duration(milliseconds: 500));
    h.timers.pendingOneShots.single.fire();
    expect(h.dashboard.repaintCount, 2);
    // The deferred timer was one-shot: it cannot fire a second time.
    expect(h.timers.pendingOneShots, isEmpty);

    // The periodic ticker repaints once per interval boundary, never per
    // event: 3 paints in 2 ticks (+ initial), i.e. at most 2 per second.
    h.clock.advance(const Duration(milliseconds: 500));
    h.timers.periodics.single.fire();
    expect(h.dashboard.repaintCount, 3);

    h.clock.advance(const Duration(milliseconds: 500));
    h.timers.periodics.single.fire();
    expect(h.dashboard.repaintCount, 4);

    // Without a tick or input nothing repaints, however long we wait.
    await _pump();
    await _pump();
    expect(h.dashboard.repaintCount, 4);

    input.add('q');
    await done;
    expect(server.stopCount, 1);
  });

  test('deferred repaint is skipped when a newer paint already happened',
      () async {
    final server = _FakeBridgeServer();
    final out = _RecordingSink();
    final input = StreamController<String>();
    final h = _dashboard(server, out, input);
    final done = h.dashboard.run();
    await _pump();
    expect(h.dashboard.repaintCount, 1);

    // A non-forced request schedules the deferred repaint (dirty)…
    input.add('x');
    await _pump();
    expect(h.timers.pendingOneShots, hasLength(1));

    // …then a periodic tick past the interval boundary paints immediately
    // (clearing the dirty flag) WITHOUT cancelling the pending deferred
    // timer — the immediate path only paints, it does not touch it.
    h.clock.advance(const Duration(milliseconds: 500));
    h.timers.periodics.single.fire();
    expect(h.dashboard.repaintCount, 2);
    expect(h.timers.pendingOneShots, hasLength(1));

    // The still-pending deferred timer fires but must NOT paint again:
    // nothing is dirty, so the coalesced request is dropped.
    h.timers.pendingOneShots.single.fire();
    expect(h.dashboard.repaintCount, 2);

    // By contrast, forced repaints ('r') cancel the pending deferred timer
    // outright — it can never fire afterwards.
    input.add('x');
    await _pump();
    expect(h.timers.pendingOneShots, hasLength(1));
    input.add('r');
    await _pump();
    expect(h.dashboard.repaintCount, 3);
    expect(h.timers.pendingOneShots, isEmpty);

    input.add('q');
    await done;
  });

  test('BridgeCallLog keeps only the newest maxEntries records', () {
    final log = BridgeCallLog(maxEntries: 3);
    for (var i = 1; i <= 5; i++) {
      log.record(
        server: 'filesys',
        tool: 't$i',
        durationMs: i,
        ok: i != 4,
        error: i == 4 ? 'boom' : null,
      );
    }
    expect(log.length, 3);
    expect(log.entries.map((e) => e.tool).toList(), <String>['t3', 't4', 't5']);
    expect(log.entries[1].ok, isFalse);
    expect(log.entries[1].error, 'boom');
    expect(log.entries.last.label, contains('t5'));
  });
}
