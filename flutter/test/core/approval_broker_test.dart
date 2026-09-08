import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/approval_broker.dart';
import 'package:shelly_hermes/core/models.dart';

void main() {
  test('request suspends until resolve delivers the decision', () async {
    final broker = ApprovalBroker();
    const call = ToolCall(id: 't1', name: 'write_file', argumentsJson: '{}');
    broker.launcher = (_) {};
    final future = broker.request(call);

    expect(broker.active?.call, call);
    var completed = false;
    unawaited(future.then((_) => completed = true));
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);

    expect(broker.resolve(ApprovalDecision.approve), isTrue);
    expect(await future, ApprovalDecision.approve);
    expect(broker.active, isNull);
  });

  test('resolve returns false when nothing is pending', () {
    final broker = ApprovalBroker();
    expect(broker.resolve(ApprovalDecision.reject), isFalse);
  });

  test('a second request replaces the pending one and resolves later',
      () async {
    final broker = ApprovalBroker();
    broker.launcher = (_) {};
    const first = ToolCall(id: 't1', name: 'a', argumentsJson: '{}');
    const second = ToolCall(id: 't2', name: 'b', argumentsJson: '{}');

    final f1 = broker.request(first);
    final f2 = broker.request(second);

    expect(broker.active?.call, second);
    // The replaced request is still resolvable through its own future only if
    // the host keeps the handle; the broker tracks only the latest one.
    var firstCompleted = false;
    unawaited(f1.then((_) => firstCompleted = true));
    broker.resolve(ApprovalDecision.reject);
    expect(await f2, ApprovalDecision.reject);
    await Future<void>.delayed(Duration.zero);
    expect(firstCompleted, isFalse);
  });

  test('launcher is invoked with each pending approval', () {
    final broker = ApprovalBroker();
    final launched = <ToolCall>[];
    broker.launcher = (approval) => launched.add(approval.call);

    const call = ToolCall(id: 't1', name: 'apply_patch_hunk', argumentsJson: '{}');
    broker.request(call);

    expect(launched, [call]);
  });

  test('approveAlways suppresses future asks for that tool name', () async {
    final broker = ApprovalBroker();
    final launched = <ToolCall>[];
    broker.launcher = (approval) => launched.add(approval.call);

    const write = ToolCall(id: 't1', name: 'write_file', argumentsJson: '{}');
    // Before approveAlways: the call suspends and goes through the launcher.
    final first = broker.request(write);
    expect(broker.active?.call, write);
    expect(broker.resolve(ApprovalDecision.approve), isTrue);
    expect(await first, ApprovalDecision.approve);

    broker.approveAlways(write);

    // After approveAlways: resolves immediately, no pending, no launcher call.
    launched.clear();
    final second =
        broker.request(const ToolCall(id: 't2', name: 'write_file', argumentsJson: '{}'));
    await Future<void>.delayed(Duration.zero);
    expect(broker.active, isNull);
    expect(launched, isEmpty);
    expect(await second, ApprovalDecision.approve);
  });

  test('approveAlways only covers the recorded tool name', () async {
    final broker = ApprovalBroker();
    broker.launcher = (_) {};
    broker.approveAlways(
        const ToolCall(id: 't1', name: 'write_file', argumentsJson: '{}'));

    const other = ToolCall(id: 't2', name: 'run_command', argumentsJson: '{}');
    final future = broker.request(other);
    expect(broker.active?.call, other);
    unawaited(future);
    expect(broker.resolve(ApprovalDecision.reject), isTrue);
    expect(await future, ApprovalDecision.reject);
  });

  test('clearAllowSet restores asking for previously allowed tools', () async {
    final broker = ApprovalBroker();
    final launched = <ToolCall>[];
    broker.launcher = (approval) => launched.add(approval.call);

    const write = ToolCall(id: 't1', name: 'write_file', argumentsJson: '{}');
    broker.approveAlways(write);
    expect(broker.allowSetView, ['write_file']);
    expect(await broker.request(write), ApprovalDecision.approve);

    broker.clearAllowSet();
    expect(broker.allowSetView, isEmpty);

    launched.clear();
    final future = broker.request(write);
    expect(broker.active?.call, write);
    expect(launched, [write]);
    expect(broker.resolve(ApprovalDecision.reject), isTrue);
    expect(await future, ApprovalDecision.reject);
  });

  test('the allow set does not persist across broker instances', () async {
    final first = ApprovalBroker();
    first.launcher = (_) {};
    const write = ToolCall(id: 't1', name: 'write_file', argumentsJson: '{}');
    first.approveAlways(write);
    expect(await first.request(write), ApprovalDecision.approve);

    // A fresh session (new broker instance) starts from an empty allow set.
    final second = ApprovalBroker();
    second.launcher = (approval) => approval.decision.complete(ApprovalDecision.reject);
    expect(second.allowSetView, isEmpty);
    expect(await second.request(write), ApprovalDecision.reject);
  });

  test('allowSetView is unmodifiable', () {
    final broker = ApprovalBroker();
    broker.approveAlways(
        const ToolCall(id: 't1', name: 'write_file', argumentsJson: '{}'));
    final view = broker.allowSetView;
    expect(() => (view as List<String>).add('run_command'), throwsUnsupportedError);
    expect(() => (view as List<String>).remove('write_file'),
        throwsUnsupportedError);
    expect(broker.allowSetView, ['write_file']);
  });

  test('approveAlways composes on top of existing flows unchanged', () async {
    final broker = ApprovalBroker();
    final launched = <ToolCall>[];
    broker.launcher = (approval) => launched.add(approval.call);

    // The resolve/active API keeps working while a name is allow-listed.
    broker.approveAlways(
        const ToolCall(id: 't1', name: 'write_file', argumentsJson: '{}'));
    expect(broker.resolve(ApprovalDecision.reject), isFalse);

    // Different tool names still take the normal pending path and can be
    // resolved individually.
    const a = ToolCall(id: 't2', name: 'a', argumentsJson: '{}');
    const b = ToolCall(id: 't3', name: 'b', argumentsJson: '{}');
    final fa = broker.request(a);
    expect(broker.active?.call, a);
    expect(broker.resolve(ApprovalDecision.approve), isTrue);
    expect(await fa, ApprovalDecision.approve);

    final fb = broker.request(b);
    expect(broker.active?.call, b);
    expect(broker.resolve(ApprovalDecision.reject), isTrue);
    expect(await fb, ApprovalDecision.reject);

    // The allowed name is still suppressed after other tools asked.
    expect(broker.allowSetView, ['write_file']);
    launched.clear();
    expect(
        await broker.request(
            const ToolCall(id: 't4', name: 'write_file', argumentsJson: '{}')),
        ApprovalDecision.approve);
    expect(launched, isEmpty);
  });
}
