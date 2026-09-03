import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/approval_broker.dart' show PendingApproval;
import '../../design/components/buttons.dart';
import '../../design/components/gradient_avatar.dart';
import '../../design/components/markdown_text.dart';
import '../../design/components/skeleton.dart';
import '../../design/components/tool_card.dart';
import '../../design/tokens.dart';
import '../../platform/platform_workspace.dart' show ResilientWorkspace;
import '../../state/chat_session.dart';
import '../../state/dsh_provider.dart';
import '../../state/settings_store.dart';
import '../approval/approval_sheet.dart';

/// The conversation tab: streaming transcript, tool cards, token usage and
/// the approval modal, all driven by [chatSessionProvider].
class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _composer = TextEditingController();
  final _scroll = ScrollController();
  bool _approvalSheetOpen = false;

  @override
  void dispose() {
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send([String? preset]) {
    final text = (preset ?? _composer.text).trim();
    if (text.isEmpty) return;
    _composer.clear();
    ref.read(chatSessionProvider.notifier).send(text);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: AppMotion.normal,
        curve: AppMotion.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(chatSessionProvider);
    final storeAsync = ref.watch(settingsStoreProvider);
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;

    // Hand the loaded store to the session controller (idempotent).
    storeAsync.whenData((store) {
      ref.read(chatSessionProvider.notifier).attach(store);
    });

    final demoMode = storeAsync.maybeWhen(
      data: (store) => !store.modelConfig.isComplete,
      orElse: () => true,
    );
    final workspaceReady = ref
            .watch(workspaceAuthorizedProvider)
            .asData
            ?.value ??
        true;

    Future<void> pickWorkspaceDirectory() async {
      final workspace = ref.read(workspaceProvider);
      if (workspace is ResilientWorkspace) {
        await workspace.pickDirectory();
      }
      ref.invalidate(workspaceAuthorizedProvider);
    }

    // Open the approval modal the first time a request lands; it stays up
    // until the queue drains (sequential hunk requests keep it open).
    ref.listen<List<PendingApproval>>(approvalQueueProvider, (prev, next) {
      if (!_approvalSheetOpen &&
          next.isNotEmpty &&
          ref.read(chatSessionProvider).phase == SessionPhase.waitingApproval) {
        _approvalSheetOpen = true;
        showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          isDismissible: false,
          enableDrag: false,
          backgroundColor: Colors.transparent,
          builder: (_) => const ApprovalSheet(),
        ).whenComplete(() => _approvalSheetOpen = false);
      }
    });

    ref.listen<ChatSessionState>(chatSessionProvider, (prev, next) {
      if (prev?.entries.length != next.entries.length ||
          prev?.phase != next.phase) {
        _scrollToBottom();
      }
    });

    return Scaffold(
      backgroundColor: semantic.background,
      body: SafeArea(
        child: Column(
          children: [
            _Header(demoMode: demoMode),
            if (!workspaceReady)
              _WorkspaceBanner(onPick: pickWorkspaceDirectory),
            if (demoMode) _DemoBanner(onTap: () => _send('演示补丁')),
            Expanded(
              child: session.entries.isEmpty
                  ? _Greeting(onSuggestion: _send)
                  : _Transcript(
                      entries: session.entries,
                      controller: _scroll,
                      pluginToolNames: ref
                          .watch(dshToolsProvider)
                          .specs
                          .map((spec) => spec.name)
                          .toSet(),
                    ),
            ),
            _Composer(
              controller: _composer,
              busy: session.isBusy,
              waitingApproval: session.phase == SessionPhase.waitingApproval,
              inputTokens: session.inputTokens,
              outputTokens: session.outputTokens,
              onSend: _send,
              onStop: () => ref.read(chatSessionProvider.notifier).cancel(),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.demoMode});

  final bool demoMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.sm),
      child: Row(
        children: [
          const GradientAvatar(size: AvatarSize.medium, glow: true),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Shelly',
                    style:
                        TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
                Text(
                  demoMode ? '演示模式' : '随时待命的智能助手',
                  style: TextStyle(fontSize: 12, color: semantic.textTertiary),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '开启新对话',
            onPressed: () =>
                ref.read(chatSessionProvider.notifier).newConversation(),
            icon: Icon(Icons.add_comment_outlined,
                size: 21, color: semantic.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceBanner extends StatelessWidget {
  const _WorkspaceBanner({required this.onPick});

  final Future<void> Function() onPick;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Row(
          children: [
            const Icon(Icons.folder_off_outlined,
                size: 15, color: AppColors.warning),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                '演示沙箱:文件改动不会落盘,选择目录后即可真实读写',
                style:
                    TextStyle(fontSize: 12, color: semantic.textSecondary),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            GestureDetector(
              onTap: () => onPick(),
              child: Text(
                '选择目录',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.warning),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DemoBanner extends StatelessWidget {
  const _DemoBanner({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Material(
        color: AppColors.brandBlue.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md, vertical: AppSpacing.sm),
            child: Row(
              children: [
                const Icon(Icons.science_outlined,
                    size: 15, color: AppColors.brandBlue),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    '演示模式:未配置模型接口,点击体验工具审批流程',
                    style:
                        TextStyle(fontSize: 12, color: semantic.textSecondary),
                  ),
                ),
                Icon(Icons.chevron_right, size: 15, color: semantic.textTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Greeting extends StatelessWidget {
  const _Greeting({required this.onSuggestion});

  final ValueChanged<String> onSuggestion;

  static const _suggestions = [
    (Icons.widgets_outlined, '演示工具', '运行一次只读工具,看看工具卡长什么样'),
    (Icons.difference_outlined, '演示补丁', '体验逐 hunk 审批的代码补丁流程'),
    (Icons.lightbulb_outline, '介绍一下自己', '了解 Shelly 能为我做什么'),
  ];

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        children: [
          const SizedBox(height: AppSpacing.xxl),
          const GradientAvatar(size: AvatarSize.large, glow: true),
          const SizedBox(height: AppSpacing.lg),
          Text('你好,我是 Shelly',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '把任务交给我,我会拆解步骤、调用工具,\n并在关键操作前征求你的同意。',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 14, height: 1.6, color: semantic.textSecondary),
          ),
          const SizedBox(height: AppSpacing.xl),
          ..._suggestions.map((s) => Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: Material(
                  color: semantic.card,
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  child: InkWell(
                    onTap: () => onSuggestion(s.$2),
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(AppRadius.lg),
                        border: Border.all(color: semantic.border),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: AppColors.brandBlue.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(AppRadius.sm),
                            ),
                            child: Icon(s.$1, size: 17, color: AppColors.brandBlue),
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(s.$2,
                                    style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600)),
                                const SizedBox(height: 2),
                                Text(s.$3,
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: semantic.textTertiary)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              )),
        ],
      ),
    );
  }
}

class _Transcript extends StatelessWidget {
  const _Transcript({
    required this.entries,
    required this.controller,
    this.pluginToolNames = const {},
  });

  final List<ChatEntry> entries;
  final ScrollController controller;

  /// DSH tool names currently registered; entries hitting these render with
  /// the 插件 badge so users can tell plugin calls from core tool calls.
  final Set<String> pluginToolNames;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.sm),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        return switch (entry) {
          UserEntry() => _UserBubble(text: entry.text),
          AssistantEntry() => _AssistantMessage(entry: entry),
          ToolEntry() => ToolCard(
              entry: entry,
              isPlugin: pluginToolNames.contains(entry.call.name),
            ),
          ErrorEntry() => _ErrorBubble(text: entry.text),
        };
      },
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.sm + 2),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: AppColors.brandGradient),
          borderRadius: BorderRadius.circular(AppRadius.lg).copyWith(
            bottomRight: const Radius.circular(AppRadius.sm),
          ),
        ),
        child: Text(text,
            style: const TextStyle(
                fontSize: 14.5, height: 1.5, color: Colors.white)),
      ),
    );
  }
}

class _AssistantMessage extends StatelessWidget {
  const _AssistantMessage({required this.entry});

  final AssistantEntry entry;

  @override
  Widget build(BuildContext context) {
    final empty = entry.text.isEmpty && entry.streaming;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (empty)
            const SkeletonMessageRow()
          else ...[
            MarkdownText(data: entry.text),
            if (entry.streaming) const _StreamingCursor(),
          ],
        ],
      ),
    );
  }
}

class _StreamingCursor extends StatefulWidget {
  const _StreamingCursor();

  @override
  State<_StreamingCursor> createState() => _StreamingCursorState();
}

class _StreamingCursorState extends State<_StreamingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _blink,
      child: Container(
        width: 3,
        height: 16,
        margin: const EdgeInsets.only(top: 2),
        decoration: BoxDecoration(
          color: AppColors.brandBlue,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

class _ErrorBubble extends StatelessWidget {
  const _ErrorBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 16, color: AppColors.danger),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 13, height: 1.5, color: semantic.textPrimary)),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.busy,
    required this.waitingApproval,
    required this.inputTokens,
    required this.outputTokens,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final bool busy;
  final bool waitingApproval;
  final int inputTokens;
  final int outputTokens;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Container(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.md),
      decoration: BoxDecoration(
        color: semantic.background,
        border: Border(top: BorderSide(color: semantic.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: busy ? null : (_) => onSend(),
                  enabled: !busy || waitingApproval,
                  style: const TextStyle(fontSize: 14.5, height: 1.4),
                  decoration: InputDecoration(
                    hintText: waitingApproval ? '请在上方做出审批决定…' : '给 Shelly 发送消息…',
                    hintStyle:
                        TextStyle(fontSize: 13.5, color: semantic.textTertiary),
                    filled: true,
                    fillColor: semantic.card,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md, vertical: AppSpacing.sm + 4),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.xl),
                      borderSide: BorderSide(color: semantic.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.xl),
                      borderSide: BorderSide(color: semantic.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.xl),
                      borderSide: const BorderSide(color: AppColors.brandBlue),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              if (busy)
                _StopButton(onStop: onStop)
              else
                GradientButton(
                  label: '',
                  icon: Icons.arrow_upward_rounded,
                  onPressed: onSend,
                ),
            ],
          ),
          if (inputTokens + outputTokens > 0)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                '输入 $inputTokens · 输出 $outputTokens tokens',
                style:
                    TextStyle(fontSize: 10.5, color: semantic.textTertiary),
              ),
            ),
        ],
      ),
    );
  }
}

class _StopButton extends StatelessWidget {
  const _StopButton({required this.onStop});

  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return GestureDetector(
      onTap: onStop,
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: semantic.card,
          shape: BoxShape.circle,
          border: Border.all(color: semantic.border),
        ),
        child: const Icon(Icons.stop, size: 22),
      ),
    );
  }
}
