import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/components/empty_state.dart';
import '../../design/tokens.dart';
import '../../state/chat_session.dart';
import '../../state/settings_store.dart';
import '../shell/home_shell.dart';

/// Conversation history backed by persisted checkpoints. Tapping a
/// conversation restores its transcript into the chat page.
class HistoryPage extends ConsumerWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final storeAsync = ref.watch(settingsStoreProvider);

    final conversations = storeAsync.maybeWhen(
      data: (store) => store.loadConversations(),
      orElse: () => const <ConversationSummary>[],
    );

    return Scaffold(
      backgroundColor: semantic.background,
      appBar: AppBar(
        titleSpacing: AppSpacing.lg,
        title: Text('历史',
            style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w700,
                color: semantic.textPrimary)),
        actions: [
          if (conversations.isNotEmpty)
            IconButton(
              tooltip: '清空历史列表',
              onPressed: () => _confirmClear(context, ref),
              icon: const Icon(Icons.delete_sweep_outlined, size: 22),
            ),
        ],
      ),
      body: conversations.isEmpty
          ? const EmptyState(
              icon: Icons.history_rounded,
              title: '还没有历史对话',
              body: '完成一次对话后,可以在这里回到当时的进度继续。',
            )
          : RefreshIndicator(
              onRefresh: () async =>
                  ref.invalidate(settingsStoreProvider),
              child: ListView.builder(
                padding: const EdgeInsets.all(AppSpacing.lg),
                itemCount: conversations.length,
                itemBuilder: (context, index) {
                  final conversation = conversations[index];
                  return _ConversationTile(conversation: conversation);
                },
              ),
            ),
    );
  }

  void _confirmClear(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空历史列表'),
        content: const Text('仅从列表移除这些会话的标题,不会删除已有内容文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              final storeAsync = ref.read(settingsStoreProvider);
              storeAsync.whenData((store) async {
                await store.saveConversations(const []);
                ref.invalidate(settingsStoreProvider);
              });
            },
            child: const Text('清空',
                style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
  }
}

class _ConversationTile extends ConsumerWidget {
  const _ConversationTile({required this.conversation});

  final ConversationSummary conversation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: semantic.border),
      ),
      child: ListTile(
        tileColor: semantic.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
        leading: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: AppColors.brandViolet.withValues(alpha: 0.13),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: const Icon(Icons.forum_outlined,
              size: 18, color: AppColors.brandViolet),
        ),
        title: Text(
          conversation.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              color: semantic.textPrimary),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            '${conversation.messageCount} 条消息 · ${_formatTime(conversation.updatedAt)}',
            style: TextStyle(fontSize: 12, color: semantic.textTertiary),
          ),
        ),
        trailing: Text('恢复',
            style: TextStyle(fontSize: 12.5, color: AppColors.brandBlue)),
        onTap: () {
          final session = ref.read(chatSessionProvider);
          if (session.isBusy) return;
          ref.read(chatSessionProvider.notifier).resume(conversation.id);
          ref.read(tabIndexProvider.notifier).state = 0;
        },
      ),
    );
  }
}

String _formatTime(DateTime time) {
  final now = DateTime.now();
  final difference = now.difference(time);
  if (difference.inMinutes < 1) return '刚刚';
  if (difference.inHours < 1) return '${difference.inMinutes} 分钟前';
  if (difference.inDays < 1) return '${difference.inHours} 小时前';
  if (difference.inDays < 30) return '${difference.inDays} 天前';
  return '${time.year}/${time.month}/${time.day}';
}
