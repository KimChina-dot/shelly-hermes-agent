/// PHASE 52 — compact context-usage meter above the composer.
///
/// The meter renders between the transcript and the queued-chips/composer
/// area only while `ChatSessionState.inputTokens > 0`. Visibility, progress
/// fraction, k-notation label and severity tint are checked against the
/// real [ChatPage] widget driven through the scripted-gateway +
/// `chatGatewayOverrideProvider` pattern from `regenerate_test.dart`
/// (plus direct [ChatSessionController.recordTokens] injection where only
/// the token state matters, e.g. tint escalation samples).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shelly_hermes/core/agent_core.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/design/theme.dart';
import 'package:shelly_hermes/design/tokens.dart';
import 'package:shelly_hermes/features/chat/chat_page.dart';
import 'package:shelly_hermes/state/chat_session.dart';
import 'package:shelly_hermes/state/settings_store.dart';

/// Gateway stub that replays canned replies (no sockets); streams the full
/// reply text in one delta so the transcript entry fills exactly like the
/// demo gateway does.
class _ScriptedGateway implements StreamingModelGateway {
  _ScriptedGateway(this.replies);

  final List<ModelReply> replies;

  @override
  Future<ModelReply> complete(List<AgentMessage> messages) async =>
      replies.removeAt(0);

  @override
  Future<ModelReply> completeStreaming(
    List<AgentMessage> messages,
    void Function(String text) onDelta,
  ) async {
    final reply = await complete(messages);
    if (reply.content.isNotEmpty) onDelta(reply.content);
    return reply;
  }
}

/// Pumps the real [ChatPage] bound to [container] so provider overrides
/// (scripted gateway) reach the page, with the app theme so
/// [AppSemanticColors] resolves exactly as in production.
Future<void> _pumpChatPage(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildShellyTheme(Brightness.light),
        home: const ChatPage(),
      ),
    ),
  );
  // Advance fake time: unmounting a previous tree schedules riverpod's
  // zero-duration provider-dispose timer, which pumpAndSettle alone
  // (no scheduled frames) would leave pending at the invariant check.
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pumpAndSettle();
}

/// Drives the scripted round to completion by pumping (widget tests run in
/// a fake-async zone: gateway futures are microtasks, timers need pumps).
Future<void> _sendAndWaitIdle(
  WidgetTester tester,
  ProviderContainer container,
  String text,
) async {
  await container.read(chatSessionProvider.notifier).send(text);
  for (var i = 0; i < 400; i += 1) {
    await tester.pump(const Duration(milliseconds: 10));
    if (!container.read(chatSessionProvider).isBusy) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('chat task did not return to idle');
}

/// Builds an empty attached session container over mocked prefs.
Future<ProviderContainer> _sessionContainer({
  List<ModelReply> replies = const [],
}) async {
  final container = ProviderContainer(
    overrides: [
      chatGatewayOverrideProvider.overrideWith((ref) => _ScriptedGateway(
            List.of(replies),
          )),
    ],
  );
  final store = SettingsStore(await SharedPreferences.getInstance());
  container.read(chatSessionProvider.notifier).attach(store);
  return container;
}

AppSemanticColors _semanticOf(WidgetTester tester) {
  final context = tester.element(find.byType(LinearProgressIndicator));
  return Theme.of(context).extension<AppSemanticColors>()!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('meter hidden while inputTokens is 0 (empty conversation)',
      (tester) async {
    final container = await _sessionContainer();
    addTearDown(container.dispose);

    expect(container.read(chatSessionProvider).inputTokens, 0);
    await _pumpChatPage(tester, container);

    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.textContaining('上下文'), findsNothing);
  });

  testWidgets('meter visible with budget fraction after a scripted round',
      (tester) async {
    final container = await _sessionContainer(
      replies: [
        // Brain classify prefill (PHASE 8): zero tokens, off the meter.
        const ModelReply(content: 'quickAnswer'),
        const ModelReply(content: '已收到', inputTokens: 12345, outputTokens: 500),
      ],
    );
    addTearDown(container.dispose);

    await _sendAndWaitIdle(tester, container, '你好');
    expect(container.read(chatSessionProvider).inputTokens, 12345);

    await _pumpChatPage(tester, container);

    // Right-aligned k-notation label under the 64000-token budget.
    expect(find.text('上下文 ~12.3k / 64k'), findsOneWidget);

    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(12345 / 64000, 1e-9));
    // Slim: the meter stays within the 2-3px band.
    expect(bar.minHeight, lessThanOrEqualTo(3));

    // Below the 70% threshold the bar stays on the quiet tertiary tint.
    expect(bar.valueColor!.value, _semanticOf(tester).textTertiary);
  });

  testWidgets('label uses k-notation: one decimal below 10k, integer k above',
      (tester) async {
    final container = await _sessionContainer();
    addTearDown(container.dispose);
    final controller = container.read(chatSessionProvider.notifier);
    await _pumpChatPage(tester, container);

    // 5000 tokens -> 5.0k keeps the decimal for precision at small values.
    controller.recordTokens(5000, 0);
    await tester.pumpAndSettle();
    expect(find.text('上下文 ~5.0k / 64k'), findsOneWidget);

    // Cumulative 12345 tokens -> 12.3k keeps a decimal while fractional.
    controller.recordTokens(7345, 0);
    await tester.pumpAndSettle();
    expect(find.text('上下文 ~12.3k / 64k'), findsOneWidget);

    // Cumulative 64000 tokens (at budget) -> integer k, no .0 noise.
    controller.recordTokens(51655, 0);
    await tester.pumpAndSettle();
    expect(find.text('上下文 ~64k / 64k'), findsOneWidget);
  });

  testWidgets('meter tints warning at >=70% and danger at >=90%',
      (tester) async {
    final container = await _sessionContainer();
    addTearDown(container.dispose);
    final controller = container.read(chatSessionProvider.notifier);

    // 48000/64000 = 75% -> warning band.
    controller.recordTokens(48000, 0);
    await _pumpChatPage(tester, container);
    expect(find.text('上下文 ~48k / 64k'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator),
          )
          .valueColor!
          .value,
      _semanticOf(tester).warning,
    );

    // 60000/64000 = 93.75% -> danger band.
    controller.recordTokens(12000, 0);
    await tester.pumpAndSettle();
    expect(find.text('上下文 ~60k / 64k'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(60000 / 64000, 1e-9));
    expect(bar.valueColor!.value, _semanticOf(tester).danger);

    // Beyond budget the fraction clamps to 1.0 and stays danger.
    controller.recordTokens(10000, 0);
    await tester.pumpAndSettle();
    final clamped = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(clamped.value, 1.0);
    expect(clamped.valueColor!.value, _semanticOf(tester).danger);
  });

  testWidgets('meter danger tint after a scripted heavy round', (tester) async {
    final container = await _sessionContainer(
      replies: [
        // Brain classify prefill (PHASE 8): zero tokens, off the meter.
        const ModelReply(content: 'quickAnswer'),
        const ModelReply(content: '长回复', inputTokens: 60000, outputTokens: 200),
      ],
    );
    addTearDown(container.dispose);

    await _sendAndWaitIdle(tester, container, '大问题');
    await _pumpChatPage(tester, container);

    expect(find.text('上下文 ~60k / 64k'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator),
          )
          .valueColor!
          .value,
      _semanticOf(tester).danger,
    );
  });
}
