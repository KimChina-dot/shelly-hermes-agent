import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/tokens.dart';
import '../../state/chat_session.dart';
import '../../state/settings_store.dart';

/// Shared conversation management actions used by the chat session sheet
/// and the history page. Each mutation refreshes the store providers.

Future<void> renameConversationDialog(
  BuildContext context,
  WidgetRef ref,
  SettingsStore store,
  ConversationSummary conversation,
) async {
  final controller = TextEditingController(text: conversation.title);
  final renamed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('重命名会话'),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 60,
        decoration: const InputDecoration(hintText: '会话名称'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('保存'),
        ),
      ],
    ),
  );
  if (renamed != true) return;
  final title = controller.text.trim();
  if (title.isNotEmpty) {
    await store.renameConversation(conversation.id, title);
  }
  ref.invalidate(settingsStoreProvider);
}

Future<void> deleteConversationDialog(
  BuildContext context,
  WidgetRef ref,
  SettingsStore store,
  ConversationSummary conversation,
) async {
  final deleted = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('删除会话'),
      content: Text('将删除「${conversation.title}」的消息记录与断点,不可恢复。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('删除', style: TextStyle(color: AppColors.danger)),
        ),
      ],
    ),
  );
  if (deleted != true) return;
  final currentId = ref.read(chatSessionProvider).conversationId;
  if (currentId == conversation.id) {
    // Deleting the open conversation also resets the chat page.
    await ref.read(chatSessionProvider.notifier).deleteCurrentConversation();
  } else {
    await store.deleteConversation(conversation.id);
  }
  ref.invalidate(settingsStoreProvider);
}

Future<void> toggleConversationPin(
  WidgetRef ref,
  SettingsStore store,
  ConversationSummary conversation,
) async {
  // setPinned currently writes the previous flag back, ignoring the
  // requested state, so the toggle applies the new flag itself and
  // persists through saveConversations to guarantee the pin lands.
  final summaries = store.loadConversations();
  final index = summaries.indexWhere((c) => c.id == conversation.id);
  if (index < 0) return;
  final current = summaries[index];
  summaries[index] = ConversationSummary(
    id: current.id,
    title: current.title,
    updatedAt: current.updatedAt,
    messageCount: current.messageCount,
    pinned: !current.pinned,
    modelId: current.modelId,
  );
  await store.saveConversations(summaries);
  ref.invalidate(settingsStoreProvider);
}
