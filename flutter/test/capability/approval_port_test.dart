import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/capability/approval/approval_port.dart';
import 'package:shelly_hermes/core/approval_broker.dart';

/// PHASE 12 (R7): the ApprovalPort contract. The production broker must
/// satisfy the capability seam with byte-identical behavior — every test
/// drives the approval flow strictly through the [ApprovalPort] type, so the
/// broker satisfying the interface is proven both at compile time and here.
void main() {
  test('ApprovalBroker satisfies the ApprovalPort interface', () {
    final broker = ApprovalBroker();

    // Compile-time proof: the broker is assignable to the port type.
    final ApprovalPort port = broker;
    expect(port, same(broker));
    expect(broker, isA<ApprovalPort>());
  });

  test('request through the port suspends until resolve approves', () async {
    final broker = ApprovalBroker();
    final ApprovalPort port = broker;
    const call = ToolCall(id: 't1', name: 'write_file', argumentsJson: '{}');
    final launched = <PendingApproval>[];
    broker.launcher = launched.add;

    final future = port.request(call);
    expect(launched, hasLength(1));
    expect(launched.single.call, call);

    var completed = false;
    unawaited(future.then((_) => completed = true));
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);

    expect(port.resolve(ApprovalDecision.approve), isTrue);
    expect(await future, ApprovalDecision.approve);
  });

  test('request through the port delivers a reject decision', () async {
    final broker = ApprovalBroker();
    final ApprovalPort port = broker;
    const call = ToolCall(id: 't1', name: 'run_command', argumentsJson: '{}');
    broker.launcher = (_) {};

    final future = port.request(call);
    expect(port.resolve(ApprovalDecision.reject), isTrue);
    expect(await future, ApprovalDecision.reject);

    // The rejection cleared the slot: nothing is pending anymore.
    expect(port.resolve(ApprovalDecision.approve), isFalse);
  });

  test('resolve on the port returns false when nothing is pending', () {
    final ApprovalPort port = ApprovalBroker();
    expect(port.resolve(ApprovalDecision.approve), isFalse);
  });

  test('an always-allow hit passes request directly without asking',
      () async {
    final broker = ApprovalBroker();
    final ApprovalPort port = broker;
    const write = ToolCall(id: 't1', name: 'write_file', argumentsJson: '{}');
    port.approveAlways(write);

    final launched = <PendingApproval>[];
    broker.launcher = launched.add;

    final future = port.request(
        const ToolCall(id: 't2', name: 'write_file', argumentsJson: '{}'));
    await Future<void>.delayed(Duration.zero);
    expect(launched, isEmpty);
    expect(broker.active, isNull);
    expect(await future, ApprovalDecision.approve);
  });

  test('approveAlways exempts only later same-name calls from approval',
      () async {
    final ApprovalPort port = ApprovalBroker();
    port.approveAlways(
        const ToolCall(id: 't1', name: 'write_file', argumentsJson: '{}'));

    // Same name: no approval needed.
    expect(
        await port.request(
            const ToolCall(id: 't2', name: 'write_file', argumentsJson: '{}')),
        ApprovalDecision.approve);

    // Different name: the normal ask flow still runs through the port.
    const other = ToolCall(id: 't3', name: 'run_command', argumentsJson: '{}');
    final future = port.request(other);
    var completed = false;
    unawaited(future.then((_) => completed = true));
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    expect(port.resolve(ApprovalDecision.reject), isTrue);
    expect(await future, ApprovalDecision.reject);
  });

  test('isAlwaysAllowed on the port reflects the session allow set', () {
    final ApprovalPort port = ApprovalBroker();
    expect(port.isAlwaysAllowed('write_file'), isFalse);

    port.approveAlways(
        const ToolCall(id: 't1', name: 'write_file', argumentsJson: '{}'));
    expect(port.isAlwaysAllowed('write_file'), isTrue);
    expect(port.isAlwaysAllowed('run_command'), isFalse);
  });
}
