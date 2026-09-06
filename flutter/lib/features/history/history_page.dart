import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/task_recovery.dart';
import '../../design/components/empty_state.dart';
import '../../design/components/motion.dart';
import '../../design/tokens.dart';
import '../../state/chat_session.dart';
import '../../state/conversation_search.dart';
import '../../state/settings_store.dart';
import '../chat/conversation_actions.dart';
import '../shell/home_shell.dart';

/// Conversation history backed by persisted checkpoints. Tapping a
/// conversation restores its transcript into the chat page. A collapsible
/// search entry (magnifier icon) filters conversations by title or first
/// user message with a 300ms debounce.
class HistoryPage extends ConsumerStatefulWidget {
  const HistoryPage({super.key});

  @override
  ConsumerState<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends ConsumerState<HistoryPage> {
  static const _debounceDuration = Duration(milliseconds: 300);

  final _searchController = TextEditingController();
  Timer? _debounce;

  /// Whether the search entry is expanded (default collapsed).
  bool _searchActive = false;

  /// The query actually applied to the list, updated on debounce expiry.
  String _appliedQuery = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(_debounceDuration, () {
      if (mounted) setState(() => _appliedQuery = value);
    });
  }

  void _toggleSearch() {
    _debounce?.cancel();
    setState(() {
      _searchActive = !_searchActive;
      _appliedQuery = '';
      _searchController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final storeAsync = ref.watch(settingsStoreProvider);

    final allConversations = storeAsync.maybeWhen(
      data: (store) => sortConversations(store.loadConversations()),
      orElse: () => const <ConversationSummary>[],
    );

    final searching = _appliedQuery.trim().isNotEmpty;
    final conversations = searching
        ? storeAsync.maybeWhen(
            data: (store) => searchConversations(store, _appliedQuery),
            orElse: () => const <ConversationSummary>[],
          )
        : allConversations;

    // A task that was running when the previous process died; surfaced as a
    // dedicated banner so it can be re-run from its checkpoint or dropped.
    // Hidden while searching so results stay focused.
    final interrupted = searching
        ? null
        : storeAsync.maybeWhen(
            data: (store) => const TaskRecovery().scan(store).firstOrNull,
            orElse: () => null,
          );

    return Scaffold(
      backgroundColor: semantic.background,
      appBar: AppBar(
        titleSpacing: AppSpacing.lg,
        title: _searchActive
            ? TextField(
                controller: _searchController,
                autofocus: true,
                onChanged: _onSearchChanged,
                style: TextStyle(fontSize: 16, color: semantic.textPrimary),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: '搜索标题或首条消息',
                  hintStyle: TextStyle(
                    fontSize: 16,
                    color: semantic.textTertiary,
                  ),
                  prefixIcon: Icon(
                    Icons.search,
                    size: 20,
                    color: semantic.textTertiary,
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
              )
            : Text(
                '历史',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: semantic.textPrimary,
                ),
              ),
        actions: [
          if (_searchActive)
            IconButton(
              tooltip: '关闭搜索',
              onPressed: _toggleSearch,
              icon: const Icon(Icons.close_rounded, size: 22),
            )
          else ...[
            if (allConversations.isNotEmpty)
              IconButton(
                tooltip: '搜索对话',
                onPressed: () => setState(() => _searchActive = true),
                icon: const Icon(Icons.search, size: 22),
              ),
            if (allConversations.isNotEmpty)
              IconButton(
                tooltip: '清空历史列表',
                onPressed: () => _confirmClear(context, ref),
                icon: const Icon(Icons.delete_sweep_outlined, size: 22),
              ),
          ],
        ],
      ),
      body: searching && conversations.isEmpty
          ? const EmptyState(
              icon: Icons.search_off_rounded,
              title: '未找到匹配对话',
              body: '换个关键词试试,支持匹配标题和首条消息内容。',
            )
          : !searching && conversations.isEmpty && interrupted == null
          ? const EmptyState(
              icon: Icons.history_rounded,
              title: '还没有历史对话',
              body: '完成一次对话后,可以在这里回到当时的进度继续。',
            )
          : RefreshIndicator(
              onRefresh: () async => ref.invalidate(settingsStoreProvider),
              child: ListView.builder(
                padding: const EdgeInsets.all(AppSpacing.lg),
                itemCount: conversations.length + (interrupted == null ? 0 : 1),
                itemBuilder: (context, index) {
                  if (interrupted != null && index == 0) {
                    return _InterruptedBanner(candidate: interrupted);
                  }
                  final conversation =
                      conversations[interrupted == null ? index : index - 1];
                  return StaggerIn(
                    index: index,
                    child: _ConversationTile(conversation: conversation),
                  );
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
            child: Text('清空', style: TextStyle(color: Theme.of(dialogContext).extension<AppSemanticColors>()!.danger)),
          ),
        ],
      ),
    );
  }
}

/// Banner for a task interrupted by process death: rerun it from the saved
/// checkpoint (unified runtime `recovering` state) or drop the record.
class _InterruptedBanner extends ConsumerWidget {
  const _InterruptedBanner({required this.candidate});

  final RecoveryCandidate candidate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.restore_outlined,
                size: 18,
                color: AppColors.warning,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  '有一个任务在后台被中断',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: semantic.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '开始于 ${_formatTime(candidate.record.startedAt)},'
            '可从上次检查点继续执行。',
            style: TextStyle(fontSize: 12, color: semantic.textSecondary),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              FilledButton.icon(
                onPressed: () {
                  final resumed = ref
                      .read(chatSessionProvider.notifier)
                      .recoverInterruptedTask();
                  if (resumed) {
                    ref.read(tabIndexProvider.notifier).state = 0;
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('当前有任务进行中,无法恢复')),
                    );
                  }
                },
                icon: const Icon(Icons.play_arrow_rounded, size: 16),
                label: const Text('恢复任务', style: TextStyle(fontSize: 12.5)),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  backgroundColor: AppColors.warning,
                  foregroundColor: Colors.white,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              TextButton(
                onPressed: () async {
                  await ref
                      .read(chatSessionProvider.notifier)
                      .dismissInterruptedTask();
                  ref.invalidate(settingsStoreProvider);
                },
                child: Text(
                  '忽略',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: semantic.textTertiary,
                  ),
                ),
              ),
            ],
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
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        leading: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: AppColors.brandViolet.withValues(alpha: 0.13),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: const Icon(
            Icons.forum_outlined,
            size: 18,
            color: AppColors.brandViolet,
          ),
        ),
        title: Text(
          (conversation.pinned ? '📌 ' : '') + conversation.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w600,
            color: semantic.textPrimary,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            '${conversation.messageCount} 条消息 · ${_formatTime(conversation.updatedAt)}',
            style: TextStyle(fontSize: 12, color: semantic.textTertiary),
          ),
        ),
        trailing: Text(
          '恢复',
          style: TextStyle(fontSize: 12.5, color: AppColors.brandBlue),
        ),
        onTap: () {
          final session = ref.read(chatSessionProvider);
          if (session.isBusy) return;
          ref.read(chatSessionProvider.notifier).resume(conversation.id);
          ref.read(tabIndexProvider.notifier).state = 0;
        },
        onLongPress: () => showModalBottomSheet<void>(
          context: context,
          backgroundColor: semantic.card,
          builder: (sheetContext) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.edit_outlined, size: 20),
                  title: const Text('重命名'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    final store = ref.read(settingsStoreProvider).valueOrNull;
                    if (store == null) return;
                    renameConversationDialog(context, ref, store, conversation);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.push_pin_outlined, size: 20),
                  title: Text(conversation.pinned ? '取消置顶' : '置顶'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    final store = ref.read(settingsStoreProvider).valueOrNull;
                    if (store == null) return;
                    toggleConversationPin(ref, store, conversation);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.delete_outline, size: 20),
                  title: const Text('删除'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    final store = ref.read(settingsStoreProvider).valueOrNull;
                    if (store == null) return;
                    deleteConversationDialog(context, ref, store, conversation);
                  },
                ),
              ],
            ),
          ),
        ),
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
