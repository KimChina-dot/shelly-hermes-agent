// Tests for the interactive bridge dashboard. Everything is driven through an
// injectable recording sink + an injectable stdin line stream, and the wrapped
// BridgeServer is a fake subclass, so no real terminal or HTTP server is used.
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

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 10));

BridgeDashboard _dashboard(
  _FakeBridgeServer server,
  _RecordingSink out,
  Stream<String> input, {
  Duration interval = const Duration(milliseconds: 500),
}) {
  return BridgeDashboard(
    server: server,
    token: 'secret-token',
    output: out,
    inputLines: input,
    refreshInterval: interval,
    lanAddressProvider: () async => const <String>['http://10.0.0.5:8766'],
  );
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
    final dashboard = _dashboard(server, out, input.stream);
    final done = dashboard.run();
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
    expect(dashboard.repaintCount, 1);

    input.add('q');
    await done;
    expect(server.stopCount, 1);
    expect(out.text, contains('桥接服务已停止'));
  });

  test('t toggles token masking in both directions', () async {
    final server = _FakeBridgeServer();
    final out = _RecordingSink();
    final input = StreamController<String>();
    final dashboard = _dashboard(server, out, input.stream);
    final done = dashboard.run();
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
    expect(dashboard.repaintCount, 3);

    input.add('q');
    await done;
  });

  test('scripted call log entries appear after a forced repaint', () async {
    final server = _FakeBridgeServer()
      ..health = _health([_serverEntry('filesys', alive: true, toolCount: 1)]);
    final out = _RecordingSink();
    final input = StreamController<String>();
    final dashboard = _dashboard(server, out, input.stream);
    final done = dashboard.run();
    await _pump();

    dashboard.callLog.record(
      server: 'filesys',
      tool: 'read_file',
      durationMs: 123,
      ok: true,
      time: DateTime(2026, 9, 8, 15, 30, 5),
    );
    dashboard.recordCall(
      server: 'git',
      tool: 'status',
      durationMs: 45,
      ok: false,
      error: 'boom',
    );
    expect(dashboard.callLog.length, 2);

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
    final dashboard = _dashboard(server, out, input.stream);
    final done = dashboard.run();
    await _pump();

    for (var i = 1; i <= 12; i++) {
      dashboard.callLog.record(
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
    final dashboard = _dashboard(server, out, input.stream);
    final done = dashboard.run();
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
    final dashboard = _dashboard(server, out, input.stream);
    final done = dashboard.run();
    await _pump();

    input.add('q');
    await done;
    expect(server.stopCount, 1);
    expect(out.text, contains('正在停止桥接服务…'));
  });

  test('closing the input stream quits and stops the server', () async {
    final server = _FakeBridgeServer();
    final out = _RecordingSink();
    final input = StreamController<String>();
    final dashboard = _dashboard(server, out, input.stream);
    final done = dashboard.run();
    await _pump();

    await input.close();
    await done;
    expect(server.stopCount, 1);
  });

  test('repaint loop is throttled to the refresh interval (at most 2x/sec)',
      () async {
    final server = _FakeBridgeServer()
      ..health = _health([_serverEntry('filesys', alive: true, toolCount: 3)]);
    final out = _RecordingSink();
    final input = StreamController<String>();
    final dashboard = _dashboard(server, out, input.stream);
    final done = dashboard.run();
    await _pump();
    expect(dashboard.repaintCount, 1);

    // A burst of non-forced refresh requests must not repaint immediately.
    for (var i = 0; i < 10; i++) {
      input.add('x$i');
    }
    await Future<void>.delayed(const Duration(milliseconds: 140));
    expect(dashboard.repaintCount, 1);

    // One repaint around the interval boundary (ticker + deferred coalesce).
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(dashboard.repaintCount, 2);

    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(dashboard.repaintCount, 3);

    await Future<void>.delayed(const Duration(milliseconds: 500));
    // 4 paints in ~1.6 s of wall time = at most 2 per second.
    expect(dashboard.repaintCount, 4);

    input.add('q');
    await done;
    expect(server.stopCount, 1);
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
