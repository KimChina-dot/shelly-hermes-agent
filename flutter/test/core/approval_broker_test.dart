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
}
