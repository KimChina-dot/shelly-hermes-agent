/// PHASE 51 — queued messages while busy (steering-lite).
///
/// While a task runs, `send` no longer dies on the busy-guard: text goes
/// into `ChatSessionState.queuedMessages` (FIFO, capped) and the completion
/// observer auto-dispatches the FIRST parked message as a fresh user turn —
/// one per completion, chaining across completions. Every round runs through
/// the real AgentRuntime stack with a scripted gateway override (no
/// sockets), so the dequeue exercises the exact production send path.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shelly_hermes/core/agent_core.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/state/chat_session.dart';
import 'package:shelly_hermes/state/settings_store.dart';

/// Gateway stub that replays canned replies and records every request.
/// Streams the full reply text in one delta so the transcript entry fills
/// exactly like the demo gateway does.
class _ScriptedGateway implements StreamingModelGateway {
  _ScriptedGateway(this.replies, {this.delay = Duration.zero});

  final List<ModelReply> replies;
  final Duration delay;
  final List<List<AgentMessage>> seen = [];

  @override
  Future<ModelReply> complete(List<AgentMessage> messages) async {
    // Recording happens BEFORE the delay, so "seen" grows as soon as a round
    // STARTS — polling on it never races past the reply.
    seen.add(List.of(messages));
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    // An exhausted script throws: the task fails (TaskState.failed), which
    // the steering queue must NOT auto-dequeue on.
    return replies.removeAt(0);
  }

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

ModelReply _reply(String text) => ModelReply(content: text);

List<String> _userTexts(ChatSessionState state) =>
    [for (final entry in state.entries) if (entry is UserEntry) entry.text];

Future<void> _waitForIdle(ProviderContainer container) async {
  for (var i = 0; i < 500; i += 1) {
    if (!container.read(chatSessionProvider).isBusy) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('chat task did not return to idle');
}

Future<void> _waitUntil(
  ProviderContainer container,
  bool Function(ChatSessionState state) predicate,
  String description,
) async {
  for (var i = 0; i < 500; i += 1) {
    if (predicate(container.read(chatSessionProvider))) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('condition not reached: $description');
}

Future<ChatSessionController> _attachedController(
  ProviderContainer container,
) async {
  final store = SettingsStore(await SharedPreferences.getInstance());
  final controller = container.read(chatSessionProvider.notifier);
  controller.attach(store);
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('send while busy enqueues instead of no-op, auto-sends on completion',
      () async {
    SharedPreferences.setMockInitialValues({});
    final gateway = _ScriptedGateway([_reply('第一答'), _reply('第二答')],
        delay: const Duration(milliseconds: 60));
    final container = ProviderContainer(overrides: [
      chatGatewayOverrideProvider.overrideWith((ref) => gateway),
    ]);
    addTearDown(container.dispose);
    final controller = await _attachedController(container);

    await controller.send('第一条');
    // The first model round is in flight before any busy-window assertions.
    await _waitUntil(
      container,
      (state) => state.isBusy && gateway.seen.length == 1,
      'first round started',
    );
    final entriesWhileBusy =
        container.read(chatSessionProvider).entries.length;

    // Busy send: parked in the queue, transcript untouched, no new round.
    await controller.send('排队一');
    expect(container.read(chatSessionProvider).isBusy, isTrue);
    expect(container.read(chatSessionProvider).queuedMessages, ['排队一']);
    expect(
      container.read(chatSessionProvider).entries.length,
      entriesWhileBusy,
    );
    expect(gateway.seen, hasLength(1));

    // Blank text never lands in the queue.
    await controller.send('   ');
    expect(container.read(chatSessionProvider).queuedMessages, ['排队一']);

    await _waitForIdle(container);
    final entries = container.read(chatSessionProvider).entries;
    expect(_userTexts(container.read(chatSessionProvider)),
        ['第一条', '排队一']);
    expect(
      [for (final e in entries) if (e is AssistantEntry) e.text],
      ['第一答', '第二答'],
    );
    expect(container.read(chatSessionProvider).queuedMessages, isEmpty);

    // The parked message reached the model as a fresh user turn.
    expect(gateway.seen, hasLength(2));
    expect(gateway.seen.last.last.role, MessageRole.user);
    expect(gateway.seen.last.last.content, '排队一');
  });

  test('queued messages drain FIFO, one per completion', () async {
    SharedPreferences.setMockInitialValues({});
    final gateway = _ScriptedGateway([
      _reply('答一'),
      _reply('答二'),
      _reply('答三'),
      _reply('答四'),
    ], delay: const Duration(milliseconds: 60));
    final container = ProviderContainer(overrides: [
      chatGatewayOverrideProvider.overrideWith((ref) => gateway),
    ]);
    addTearDown(container.dispose);
    final controller = await _attachedController(container);

    await controller.send('首条');
    // Round one in flight before parking the steering messages.
    await _waitUntil(
      container,
      (state) => state.isBusy && gateway.seen.length == 1,
      'first round started',
    );
    await controller.send('队列一');
    await controller.send('队列二');
    await controller.send('队列三');
    expect(
      container.read(chatSessionProvider).queuedMessages,
      ['队列一', '队列二', '队列三'],
    );

    // First completion dequeues 队列一 and its task starts running; while it
    // runs NOTHING further is dequeued (one message per completion).
    await _waitUntil(
      container,
      (state) => state.isBusy &&
          _userTexts(state).last == '队列一' &&
          gateway.seen.length == 2,
      'dequeued task for 队列一 running',
    );
    expect(_userTexts(container.read(chatSessionProvider)), hasLength(2));
    expect(
      container.read(chatSessionProvider).queuedMessages,
      ['队列二', '队列三'],
    );
    expect(gateway.seen, hasLength(2));

    await _waitForIdle(container);
    expect(
      _userTexts(container.read(chatSessionProvider)),
      ['首条', '队列一', '队列二', '队列三'],
    );
    expect(container.read(chatSessionProvider).queuedMessages, isEmpty);
    expect(gateway.seen, hasLength(4));
    expect(
      [for (final round in gateway.seen) round.last.content],
      ['首条', '队列一', '队列二', '队列三'],
    );
  });

  test('queue caps at 5 and drops the oldest', () async {
    SharedPreferences.setMockInitialValues({});
    final gateway = _ScriptedGateway([
      _reply('答零'),
      _reply('答三'),
      _reply('答四'),
      _reply('答五'),
      _reply('答六'),
      _reply('答七'),
    ], delay: const Duration(milliseconds: 40));
    final container = ProviderContainer(overrides: [
      chatGatewayOverrideProvider.overrideWith((ref) => gateway),
    ]);
    addTearDown(container.dispose);
    final controller = await _attachedController(container);
    // PHASE 54 interrupt-and-steer would consume the second send as an
    // interrupt (empty queue); this test pins the park-in-line contract,
    // so steering is off.
    controller.steerMode = false;

    await controller.send('首条');
    for (final text in ['q一', 'q二', 'q三', 'q四', 'q五', 'q六', 'q七']) {
      await controller.send(text);
    }
    expect(
      container.read(chatSessionProvider).queuedMessages,
      ['q三', 'q四', 'q五', 'q六', 'q七'],
    );

    await _waitForIdle(container);
    expect(
      _userTexts(container.read(chatSessionProvider)),
      ['首条', 'q三', 'q四', 'q五', 'q六', 'q七'],
    );
    expect(gateway.seen, hasLength(6));
  });

  test('removeQueuedMessage dismisses a parked message before its send',
      () async {
    SharedPreferences.setMockInitialValues({});
    final gateway = _ScriptedGateway([_reply('答一'), _reply('答乙')],
        delay: const Duration(milliseconds: 60));
    final container = ProviderContainer(overrides: [
      chatGatewayOverrideProvider.overrideWith((ref) => gateway),
    ]);
    addTearDown(container.dispose);
    final controller = await _attachedController(container);

    await controller.send('首条');
    await controller.send('队列甲');
    await controller.send('队列乙');
    expect(
      container.read(chatSessionProvider).queuedMessages,
      ['队列甲', '队列乙'],
    );

    controller.removeQueuedMessage(0);
    expect(container.read(chatSessionProvider).queuedMessages, ['队列乙']);
    // Out-of-range indices are ignored.
    controller.removeQueuedMessage(5);
    expect(container.read(chatSessionProvider).queuedMessages, ['队列乙']);

    await _waitForIdle(container);
    expect(
      _userTexts(container.read(chatSessionProvider)),
      ['首条', '队列乙'],
    );
    expect(
      gateway.seen.expand((round) => round.map((m) => m.content)),
      isNot(contains('队列甲')),
    );
  });

  test('new conversation clears the queue', () async {
    SharedPreferences.setMockInitialValues({});
    // An empty script makes the round throw: the task FAILS, which does not
    // auto-dequeue — so the queue survives into the idle state.
    final gateway = _ScriptedGateway([]);
    final container = ProviderContainer(overrides: [
      chatGatewayOverrideProvider.overrideWith((ref) => gateway),
    ]);
    addTearDown(container.dispose);
    final controller = await _attachedController(container);
    // PHASE 54: steering off pins the queue-only contract for this test.
    controller.steerMode = false;

    await controller.send('首条');
    await controller.send('队列一');
    await _waitForIdle(container);

    expect(container.read(chatSessionProvider).isBusy, isFalse);
    expect(container.read(chatSessionProvider).queuedMessages, ['队列一']);

    expect(controller.newConversation(), isTrue);
    expect(container.read(chatSessionProvider).queuedMessages, isEmpty);
    expect(container.read(chatSessionProvider).entries, isEmpty);
  });

  test('interrupt-and-steer: empty-queue send cancels the task and re-sends',
      () async {
    SharedPreferences.setMockInitialValues({});
    final gateway = _ScriptedGateway([
      _reply('被打断的答'),
      _reply('转向后的答'),
    ], delay: const Duration(milliseconds: 80));
    final container = ProviderContainer(overrides: [
      chatGatewayOverrideProvider.overrideWith((ref) => gateway),
    ]);
    addTearDown(container.dispose);
    final controller = await _attachedController(container);

    await controller.send('第一条');
    await _waitUntil(
      container,
      (state) => state.isBusy && gateway.seen.length == 1,
      'first round started',
    );

    // Empty queue + steerMode on: the send interrupts and parks itself.
    expect(controller.steerMode, true);
    await controller.send('转向消息');
    expect(
      container.read(chatSessionProvider).queuedMessages,
      ['转向消息'],
    );

    // The stop propagates; the completion observer dequeues 转向消息 and
    // re-sends it through the full send path.
    await _waitUntil(
      container,
      (state) =>
          !state.isBusy &&
          _userTexts(state).contains('转向消息') &&
          state.queuedMessages.isEmpty,
      'interrupted task drained and 转向消息 re-sent',
    );
    await _waitForIdle(container);
    expect(_userTexts(container.read(chatSessionProvider)),
        ['第一条', '转向消息']);
    expect(gateway.seen, hasLength(2));
  });

  test('steerMode=false keeps the queue-only behavior while busy', () async {
    SharedPreferences.setMockInitialValues({});
    final gateway = _ScriptedGateway(
        [_reply('答一'), _reply('答二')],
        delay: const Duration(milliseconds: 80));
    final container = ProviderContainer(overrides: [
      chatGatewayOverrideProvider.overrideWith((ref) => gateway),
    ]);
    addTearDown(container.dispose);
    final controller = await _attachedController(container);

    controller.steerMode = false;
    await controller.send('第一条');
    await _waitUntil(
      container,
      (state) => state.isBusy && gateway.seen.length == 1,
      'first round started',
    );

    await controller.send('排队消息');
    // No interrupt: the task keeps running (gateway still in round 1).
    expect(gateway.seen, hasLength(1));
    expect(container.read(chatSessionProvider).queuedMessages, ['排队消息']);

    await _waitForIdle(container);
    await _waitUntil(
      container,
      (state) => _userTexts(state).contains('排队消息'),
      'queued message re-sent after completion',
    );
    await _waitForIdle(container);
    expect(_userTexts(container.read(chatSessionProvider)), ['第一条', '排队消息']);
    expect(gateway.seen, hasLength(2));
  });

  test('non-empty queue keeps park-in-line even with steerMode on',
      () async {
    SharedPreferences.setMockInitialValues({});
    final gateway = _ScriptedGateway([
      _reply('答一'),
      _reply('答二'),
      _reply('答三'),
    ], delay: const Duration(milliseconds: 80));
    final container = ProviderContainer(overrides: [
      chatGatewayOverrideProvider.overrideWith((ref) => gateway),
    ]);
    addTearDown(container.dispose);
    final controller = await _attachedController(container);

    await controller.send('首条');
    await _waitUntil(
      container,
      (state) => state.isBusy && gateway.seen.length == 1,
      'first round started',
    );

    // First send parks (empty queue → interrupt); the completion observer
    // dequeues 转向一 and starts its task right away.
    await controller.send('转向一');
    await _waitUntil(
      container,
      (state) => state.isBusy && gateway.seen.length == 2,
      '转向一 task running after the interrupt drained',
    );
    await controller.send('排队二');
    expect(gateway.seen, hasLength(2));
    expect(container.read(chatSessionProvider).queuedMessages, ['排队二']);

    await _waitForIdle(container);
    await _waitUntil(
      container,
      (state) => _userTexts(state).contains('排队二'),
      '排队二 re-sent',
    );
    await _waitForIdle(container);
    expect(_userTexts(container.read(chatSessionProvider)),
        ['首条', '转向一', '排队二']);
    expect(gateway.seen, hasLength(3));
  });
}
