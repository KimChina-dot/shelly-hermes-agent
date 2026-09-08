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

  test('initialPersistentAllow suppresses asks without a session approval',
      () async {
    final broker = ApprovalBroker(
        initialPersistentAllow: {'run_command', 'write_file'});
    final launched = <ToolCall>[];
    broker.launcher = (approval) => launched.add(approval.call);

    expect(broker.allowSetView, isEmpty);
    expect(broker.persistentAllowView, ['run_command', 'write_file']);

    // Persisted names resolve immediately: no pending, no launcher call.
    final run =
        broker.request(const ToolCall(id: 't1', name: 'run_command', argumentsJson: '{}'));
    await Future<void>.delayed(Duration.zero);
    expect(broker.active, isNull);
    expect(launched, isEmpty);
    expect(await run, ApprovalDecision.approve);

    final write =
        broker.request(const ToolCall(id: 't2', name: 'write_file', argumentsJson: '{}'));
    await Future<void>.delayed(Duration.zero);
    expect(broker.active, isNull);
    expect(launched, isEmpty);
    expect(await write, ApprovalDecision.approve);

    // Unlisted tools still go through the normal pending path.
    const other = ToolCall(id: 't3', name: 'delete_file', argumentsJson: '{}');
    final future = broker.request(other);
    expect(broker.active?.call, other);
    launched.clear();
    expect(broker.resolve(ApprovalDecision.reject), isTrue);
    expect(await future, ApprovalDecision.reject);
  });

  test('onAllowAlwaysPersist is invoked by approveAlways with the tool name',
      () {
    final persisted = <String>[];
    final broker = ApprovalBroker(onAllowAlwaysPersist: persisted.add);

    const write = ToolCall(id: 't1', name: 'write_file', argumentsJson: '{}');
    broker.approveAlways(write);
    expect(persisted, ['write_file']);

    // Invoked again per approveAlways call, dedup only in the set, not the hook.
    broker.approveAlways(write);
    expect(persisted, ['write_file', 'write_file']);

    // Plain resolves never touch the persistence hook.
    final broker2 = ApprovalBroker(onAllowAlwaysPersist: persisted.add);
    broker2.launcher = (_) {};
    broker2.request(const ToolCall(id: 't2', name: 'run_command', argumentsJson: '{}'));
    broker2.resolve(ApprovalDecision.approve);
    expect(persisted, ['write_file', 'write_file']);
  });

  test('session and persistent allow sets compose (isAlwaysAllowed from either)',
      () async {
    final broker = ApprovalBroker(initialPersistentAllow: {'a'});
    final launched = <ToolCall>[];
    broker.launcher = (approval) => launched.add(approval.call);

    // From the persistent set only.
    expect(broker.isAlwaysAllowed('a'), isTrue);
    // From the session set only.
    broker.approveAlways(
        const ToolCall(id: 't1', name: 'b', argumentsJson: '{}'));
    expect(broker.isAlwaysAllowed('b'), isTrue);
    // From neither.
    expect(broker.isAlwaysAllowed('c'), isFalse);

    expect(await broker.request(const ToolCall(id: 't2', name: 'a', argumentsJson: '{}')),
        ApprovalDecision.approve);
    expect(await broker.request(const ToolCall(id: 't3', name: 'b', argumentsJson: '{}')),
        ApprovalDecision.approve);
    await Future<void>.delayed(Duration.zero);
    expect(launched, isEmpty);

    // Session insert of a persistent name stays a no-op on the persistent view.
    broker.approveAlways(
        const ToolCall(id: 't4', name: 'a', argumentsJson: '{}'));
    expect(broker.allowSetView, unorderedEquals(['a', 'b']));
    expect(broker.persistentAllowView, ['a']);
  });

  test('clearAllowSet clears only the session set, not the persistent one',
      () async {
    final broker = ApprovalBroker(initialPersistentAllow: {'write_file'});
    final launched = <ToolCall>[];
    broker.launcher = (approval) => launched.add(approval.call);

    broker.approveAlways(
        const ToolCall(id: 't1', name: 'run_command', argumentsJson: '{}'));
    expect(broker.isAlwaysAllowed('run_command'), isTrue);

    broker.clearAllowSet();
    expect(broker.allowSetView, isEmpty);
    expect(broker.isAlwaysAllowed('run_command'), isFalse);
    // The persisted entry survives the session clear.
    expect(broker.isAlwaysAllowed('write_file'), isTrue);
    expect(broker.persistentAllowView, ['write_file']);

    // run_command asks again; write_file is still suppressed.
    const run = ToolCall(id: 't2', name: 'run_command', argumentsJson: '{}');
    final future = broker.request(run);
    expect(broker.active?.call, run);
    expect(broker.resolve(ApprovalDecision.reject), isTrue);
    expect(await future, ApprovalDecision.reject);

    expect(
        await broker.request(
            const ToolCall(id: 't3', name: 'write_file', argumentsJson: '{}')),
        ApprovalDecision.approve);
  });

  test('clearPersistentAllow revokes only the in-memory persistent mirror',
      () async {
    final broker = ApprovalBroker(initialPersistentAllow: {'a', 'b'});
    broker.approveAlways(
        const ToolCall(id: 't1', name: 'c', argumentsJson: '{}'));

    broker.clearPersistentAllow('a');
    expect(broker.persistentAllowView, ['b']);
    expect(broker.isAlwaysAllowed('a'), isFalse);
    // Session set and other persistent entries are untouched.
    expect(broker.isAlwaysAllowed('b'), isTrue);
    expect(broker.isAlwaysAllowed('c'), isTrue);

    // Clearing an unknown name is a no-op.
    broker.clearPersistentAllow('nope');
    expect(broker.persistentAllowView, ['b']);
  });

  test('persistentAllowView is unmodifiable and decoupled from the input set',
      () {
    final injected = <String>{'a'};
    final broker = ApprovalBroker(initialPersistentAllow: injected);
    final view = broker.persistentAllowView;

    expect(() => (view as List<String>).add('b'), throwsUnsupportedError);
    expect(() => (view as List<String>).remove('a'), throwsUnsupportedError);

    // Mutating the caller's set afterwards does not leak into the broker.
    injected.add('late');
    expect(broker.persistentAllowView, ['a']);
    expect(broker.isAlwaysAllowed('late'), isFalse);
  });

  test('no persistence hook keeps the PHASE 48 behavior unchanged', () async {
    final broker = ApprovalBroker();
    final launched = <ToolCall>[];
    broker.launcher = (approval) => launched.add(approval.call);

    // Fresh broker: nothing allowed anywhere.
    expect(broker.isAlwaysAllowed('write_file'), isFalse);
    expect(broker.allowSetView, isEmpty);
    expect(broker.persistentAllowView, isEmpty);

    // approveAlways works with the hook absent and only touches the session set.
    const write = ToolCall(id: 't1', name: 'write_file', argumentsJson: '{}');
    broker.approveAlways(write);
    expect(broker.isAlwaysAllowed('write_file'), isTrue);
    expect(broker.allowSetView, ['write_file']);
    expect(broker.persistentAllowView, isEmpty);
    expect(await broker.request(write), ApprovalDecision.approve);
    await Future<void>.delayed(Duration.zero);
    expect(launched, isEmpty);

    // clearAllowSet still drops everything (nothing persisted behind it).
    broker.clearAllowSet();
    expect(broker.isAlwaysAllowed('write_file'), isFalse);
    final future = broker.request(write);
    expect(broker.active?.call, write);
    expect(broker.resolve(ApprovalDecision.reject), isTrue);
    expect(await future, ApprovalDecision.reject);

    // clearPersistentAllow on a hook-less broker is a safe no-op.
    broker.clearPersistentAllow('write_file');
    expect(broker.persistentAllowView, isEmpty);
  });
}
