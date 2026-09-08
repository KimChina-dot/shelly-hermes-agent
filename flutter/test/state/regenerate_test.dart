/// PHASE 50 — regenerate last reply & edit-user-resend.
///
/// Every round runs through the real AgentRuntime/AgentCore stack with a
/// scripted gateway override (no sockets), so the tests exercise the same
/// checkpoint persistence path as production: truncation must be visible to
/// both the live transcript and a freshly reloaded controller.
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
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    seen.add(List.of(messages));
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

Future<void> _waitForIdle(ProviderContainer container) async {
  for (var i = 0; i < 500; i += 1) {
    if (!container.read(chatSessionProvider).isBusy) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('chat task did not return to idle');
}

Future<ChatSessionController> _attachedController(
  ProviderContainer container,
) async {
  final store = SettingsStore(await SharedPreferences.getInstance());
  final controller = container.read(chatSessionProvider.notifier);
  controller.attach(store);
  return controller;
}

/// Re-reads the persisted checkpoint through the same prefs backend the
/// controller wrote to (shared_preferences mocks are process-global).
Future<AgentCheckpoint?> _persistedCheckpoint(String conversationId) async =>
    SettingsStore(await SharedPreferences.getInstance())
        .loadCheckpoint(conversationId);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('regenerateLast drops the old reply and produces a new one', () async {
    SharedPreferences.setMockInitialValues({});
    final gateway =
        _ScriptedGateway([_reply('第一版回复'), _reply('第二版回复')]);
    final container = ProviderContainer(overrides: [
      chatGatewayOverrideProvider.overrideWith((ref) => gateway),
    ]);
    addTearDown(container.dispose);
    final controller = await _attachedController(container);

    await controller.send('你好');
    await _waitForIdle(container);
    var entries = container.read(chatSessionProvider).entries;
    expect(entries.whereType<UserEntry>().single.text, '你好');
    expect(entries.whereType<AssistantEntry>().single.text, '第一版回复');
    final conversationId =
        container.read(chatSessionProvider).conversationId!;

    expect(controller.regenerateLast(), isTrue);
    await _waitForIdle(container);

    entries = container.read(chatSessionProvider).entries;
    expect(entries.whereType<UserEntry>().single.text, '你好');
    expect(entries.whereType<AssistantEntry>().single.text, '第二版回复');
    expect(entries.whereType<ErrorEntry>(), isEmpty);
    expect(entries.whereType<ToolEntry>(), isEmpty);

    // The re-dispatch carried the SAME user message; the old reply never
    // reached the model again.
    expect(gateway.seen, hasLength(2));
    final resend = gateway.seen.last;
    expect(resend.last.role, MessageRole.user);
    expect(resend.last.content, '你好');
    expect(
      resend.map((m) => m.content),
      isNot(contains('第一版回复')),
    );

    // The persisted checkpoint reflects the regenerated round, not the
    // dropped one.
    final checkpoint = (await _persistedCheckpoint(conversationId))!;
    expect(checkpoint.messages.last.content, '第二版回复');
    expect(
      checkpoint.messages.map((m) => m.content),
      isNot(contains('第一版回复')),
    );
  });

  test('editAndResend replaces the user text and re-runs', () async {
    SharedPreferences.setMockInitialValues({});
    final gateway =
        _ScriptedGateway([_reply('原始回复'), _reply('修改后的回复')]);
    final container = ProviderContainer(overrides: [
      chatGatewayOverrideProvider.overrideWith((ref) => gateway),
    ]);
    addTearDown(container.dispose);
    final controller = await _attachedController(container);

    await controller.send('原始问题');
    await _waitForIdle(container);
    final conversationId =
        container.read(chatSessionProvider).conversationId!;

    // Blank edits are rejected before anything is touched.
    expect(controller.editAndResend('   '), isFalse);
    expect(container.read(chatSessionProvider).isBusy, isFalse);

    expect(controller.editAndResend('  修改后的问题  '), isTrue);
    await _waitForIdle(container);

    final entries = container.read(chatSessionProvider).entries;
    expect(entries.whereType<UserEntry>().single.text, '修改后的问题');
    expect(entries.whereType<AssistantEntry>().single.text, '修改后的回复');

    // The edited text reached the model and the persisted checkpoint.
    expect(gateway.seen, hasLength(2));
    expect(gateway.seen.last.last.role, MessageRole.user);
    expect(gateway.seen.last.last.content, '修改后的问题');
    final checkpoint = (await _persistedCheckpoint(conversationId))!;
    expect(
      checkpoint.messages.lastWhere((m) => m.role == MessageRole.user).content,
      '修改后的问题',
    );
  });

  test('busy-guard: regenerate and edit no-op while a task is running',
      () async {
    SharedPreferences.setMockInitialValues({});
    final gateway = _ScriptedGateway(
      [_reply('慢回复')],
      delay: const Duration(milliseconds: 400),
    );
    final container = ProviderContainer(overrides: [
      chatGatewayOverrideProvider.overrideWith((ref) => gateway),
    ]);
    addTearDown(container.dispose);
    final controller = await _attachedController(container);

    await controller.send('第一条');
    expect(container.read(chatSessionProvider).isBusy, isTrue);
    final entryCountWhileBusy =
        container.read(chatSessionProvider).entries.length;

    expect(controller.regenerateLast(), isFalse);
    expect(controller.editAndResend('改写文本'), isFalse);
    expect(
      container.read(chatSessionProvider).entries.length,
      entryCountWhileBusy,
    );

    await _waitForIdle(container);
    // Exactly one model round happened — no silent re-dispatch.
    expect(gateway.seen, hasLength(1));
    final entries = container.read(chatSessionProvider).entries;
    expect(entries.whereType<UserEntry>().single.text, '第一条');
    expect(entries.whereType<AssistantEntry>().single.text, '慢回复');
  });

  test('empty transcript: regenerate and edit are no-ops', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = await _attachedController(container);

    expect(controller.regenerateLast(), isFalse);
    expect(controller.editAndResend('新文本'), isFalse);
    expect(container.read(chatSessionProvider).entries, isEmpty);
    expect(container.read(chatSessionProvider).isBusy, isFalse);
  });

  test('checkpoint truncation persists: a fresh controller reloads only the '
      'regenerated turn', () async {
    SharedPreferences.setMockInitialValues({});
    final gateway =
        _ScriptedGateway([_reply('第一版回复'), _reply('第二版回复')]);
    final container = ProviderContainer(overrides: [
      chatGatewayOverrideProvider.overrideWith((ref) => gateway),
    ]);
    final controller = await _attachedController(container);

    await controller.send('你好');
    await _waitForIdle(container);
    expect(controller.regenerateLast(), isTrue);
    await _waitForIdle(container);
    final conversationId =
        container.read(chatSessionProvider).conversationId!;
    container.dispose();

    // A fresh controller over the same prefs rebuilds the transcript from
    // the truncated checkpoint: the dropped reply is gone for good.
    final container2 = ProviderContainer();
    addTearDown(container2.dispose);
    final controller2 = await _attachedController(container2);
    expect(controller2.switchTo(conversationId), isTrue);

    final entries = container2.read(chatSessionProvider).entries;
    expect(entries.whereType<UserEntry>().single.text, '你好');
    expect(entries.whereType<AssistantEntry>().single.text, '第二版回复');
    expect(entries.whereType<ToolEntry>(), isEmpty);
    expect(entries.whereType<ErrorEntry>(), isEmpty);
  });
}
