// PHASE 15 safety net (TEST_COVERAGE_MAP §3): direct widget tests for the
// approval sheet — the audit found zero files referencing ApprovalSheet, so
// the approval form's rendering and decision mapping had no regression net.
//
// Setup: a real ProviderContainer with the REAL chatSessionProvider — the
// controller constructor is pure wiring (no IO, no timers) — and approvals
// are surfaced exactly like production, by firing `broker.request(call)`
// unawaited so the broker's launcher callback sets phase=waitingApproval
// and fills approvalQueueProvider. The sheet is pumped inside the real
// Shelly theme (it requires the AppSemanticColors extension).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/capability/approval/approval_port.dart'
    show ApprovalDecision, PendingApproval;
import 'package:shelly_hermes/core/models.dart' show ToolCall;
import 'package:shelly_hermes/design/theme.dart';
import 'package:shelly_hermes/features/approval/approval_sheet.dart';
import 'package:shelly_hermes/state/chat_session.dart';

class _SheetHandle {
  _SheetHandle(this.container, this.controller);

  final ProviderContainer container;
  final ChatSessionController controller;

  List<PendingApproval> get queue => container.read(approvalQueueProvider);
}

/// Pumps the sheet under the real theme. Each [calls] entry is surfaced
/// through the broker like a real engine ask. [onPersistent] is the
/// cross-session remember hook (null hides the option, as in production).
Future<_SheetHandle> _pumpSheet(
  WidgetTester tester, {
  List<ToolCall> calls = const [],
  Future<void> Function(PendingApproval approval)? onPersistent,
}) async {
  // Diff cards can be tall; give the sheet room so Column never overflows.
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final container = ProviderContainer();
  addTearDown(container.dispose);
  final controller = container.read(chatSessionProvider.notifier);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildShellyTheme(Brightness.dark),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ApprovalSheet(onAllowAlwaysPersistent: onPersistent),
          ),
        ),
      ),
    ),
  );

  for (final call in calls) {
    unawaited(controller.broker.request(call));
  }
  await tester.pump();
  return _SheetHandle(container, controller);
}

const _writeCall = ToolCall(
  id: 't1',
  name: 'write_file',
  argumentsJson:
      '{"path":"docs/notes.md","content":"第一行\\n第二行"}',
);

const _runCommandCall = ToolCall(
  id: 't2',
  name: 'run_command',
  argumentsJson: '{"command":"flutter test"}',
);

void main() {
  testWidgets('renders nothing when no approval is pending', (tester) async {
    await _pumpSheet(tester);

    // The sheet collapses to SizedBox.shrink(): no header, no buttons.
    expect(find.text('需要你的批准'), findsNothing);
    expect(find.text('允许执行'), findsNothing);
  });

  testWidgets('renders the pending tool call with path, risk and actions',
      (tester) async {
    final h = await _pumpSheet(tester, calls: const [_writeCall]);

    expect(find.text('需要你的批准'), findsOneWidget);
    expect(find.text('工具 "write_file" 请求执行'), findsOneWidget);
    expect(find.text('写入文件'), findsOneWidget); // _toolTitle mapping
    expect(find.text('docs/notes.md'), findsOneWidget); // path row
    expect(find.text('新文件内容'), findsOneWidget); // write_file diff mode
    expect(find.text('+第一行'), findsOneWidget); // content as + diff lines
    expect(find.text('+第二行'), findsOneWidget);
    expect(find.text('拒绝'), findsOneWidget);
    expect(find.text('允许执行'), findsOneWidget);
    expect(find.text('本次会话不再询问此类操作'), findsOneWidget);
    // Without the wirer hook the cross-session option stays hidden.
    expect(find.text('跨会话记住此类操作'), findsNothing);
    expect(h.queue, hasLength(1));
  });

  testWidgets('renders apply_patch_hunk with segment progress and diff',
      (tester) async {
    await _pumpSheet(tester, calls: const [
      ToolCall(
        id: 't3',
        name: 'apply_patch_hunk',
        argumentsJson:
            '{"path":"lib/main.dart","hunk_index":2,"hunk_count":5,'
            '"hunk":"@@ -1,2 +1,3 @@\\n context\\n-old\\n+new"}',
      ),
    ]);

    expect(find.text('补丁共 5 段,当前第 2 段'), findsOneWidget);
    expect(find.text('补丁片段'), findsOneWidget);
    expect(find.text('-old'), findsOneWidget);
    expect(find.text('+new'), findsOneWidget);
  });

  testWidgets('shows the queue-depth hint while more approvals wait',
      (tester) async {
    final h = await _pumpSheet(tester,
        calls: const [_writeCall, _runCommandCall]);

    expect(find.text('还有 1 个请求排队中'), findsOneWidget);
    expect(h.queue, hasLength(2));
  });

  testWidgets('允许执行 approves the head request and drains it',
      (tester) async {
    final h = await _pumpSheet(tester, calls: const [_writeCall]);
    final approval = h.queue.single;

    await tester.tap(find.text('允许执行'));
    await tester.pump();

    expect(await approval.decision.future, ApprovalDecision.approve);
    expect(h.queue, isEmpty);
    // Queue empty + phase leaves waitingApproval: the sheet collapses.
    expect(find.text('需要你的批准'), findsNothing);
  });

  testWidgets('拒绝 rejects the head request and drains it', (tester) async {
    final h = await _pumpSheet(tester, calls: const [_writeCall]);
    final approval = h.queue.single;

    await tester.tap(find.text('拒绝'));
    await tester.pump();

    expect(await approval.decision.future, ApprovalDecision.reject);
    expect(h.queue, isEmpty);
    expect(find.text('需要你的批准'), findsNothing);
  });

  testWidgets('the reason field toggles and resets after a decision',
      (tester) async {
    final h = await _pumpSheet(tester, calls: const [_runCommandCall]);

    await tester.tap(find.text('附加拒绝理由'));
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    // While the field is open the toggle is replaced by the field itself.
    expect(find.text('附加拒绝理由'), findsNothing);

    await tester.enterText(find.byType(TextField), '太危险了');

    await tester.tap(find.text('拒绝'));
    await tester.pump();
    expect(h.queue, isEmpty);

    // A fresh approval renders with the reason field closed again.
    unawaited(h.controller.broker.request(_runCommandCall));
    await tester.pump();
    expect(find.text('附加拒绝理由'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('本次会话不再询问此类操作 approves once, then never asks again',
      (tester) async {
    final h = await _pumpSheet(tester, calls: const [_runCommandCall]);
    final approval = h.queue.single;

    await tester.tap(find.text('本次会话不再询问此类操作'));
    await tester.pump();

    expect(await approval.decision.future, ApprovalDecision.approve);
    expect(h.queue, isEmpty);

    // The very same tool name never surfaces an ask again this session…
    final second =
        h.controller.broker.request(const ToolCall(id: 't4', name: 'run_command', argumentsJson: '{}'));
    await tester.pump();
    expect(h.queue, isEmpty);
    expect(find.text('需要你的批准'), findsNothing);
    // …and resolves immediately with approve (broker allow-set semantics).
    expect(await second, ApprovalDecision.approve);
  });

  testWidgets('跨会话记住此类操作 appears only with the hook and hands over the approval',
      (tester) async {
    final seen = <PendingApproval>[];
    final h = await _pumpSheet(
      tester,
      calls: const [_writeCall],
      onPersistent: (approval) async => seen.add(approval),
    );

    expect(find.text('跨会话记住此类操作'), findsOneWidget);
    expect(find.text('本次会话不再询问此类操作'), findsOneWidget);

    await tester.tap(find.text('跨会话记住此类操作'));
    await tester.pump();

    // The hook receives exactly the queue head…
    expect(seen, hasLength(1));
    expect(seen.single.call, _writeCall);
    // …and the SHEET itself stays policy-free: the approval is neither
    // resolved nor drained — the wirer composes persistence + resolution.
    expect(h.queue, hasLength(1));
    expect(seen.single.decision.isCompleted, isFalse);
  });

  testWidgets('approving the head advances to the next queued request',
      (tester) async {
    final h = await _pumpSheet(tester,
        calls: const [_writeCall, _runCommandCall]);

    await tester.tap(find.text('允许执行'));
    await tester.pump();

    // The second ask is now the head; the depth hint is gone.
    expect(find.text('工具 "run_command" 请求执行'), findsOneWidget);
    expect(find.text('还有 1 个请求排队中'), findsNothing);
    expect(h.queue, hasLength(1));
  });
}
