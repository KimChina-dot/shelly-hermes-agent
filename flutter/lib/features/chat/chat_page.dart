import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/approval_broker.dart' show PendingApproval;
import '../../core/models.dart' show TextFileAttachment;
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
import 'conversation_actions.dart';
import 'model_picker_sheet.dart';

/// Maximum attached images per message, so the request payload stays sane.
const _maxImagesPerMessage = 4;

/// Maximum attached text files per message and per-file byte cap.
const _maxFilesPerMessage = 4;
const _maxTextFileBytes = 200 * 1024;

/// Injectable gallery-photo picker; widget tests swap this out because the
/// real one needs the image_picker platform channel.
Future<String?> Function() pickGalleryImage = _defaultPickGalleryImage;

/// Injectable text-file picker; tests swap this out for the same reason.
Future<TextFileAttachment> Function() pickTextFile = _defaultPickTextFile;

void resetGalleryImagePicker() => pickGalleryImage = _defaultPickGalleryImage;

void resetTextFilePicker() => pickTextFile = _defaultPickTextFile;

const _textLikeExtensions = [
  'txt', 'md', 'markdown', 'csv', 'tsv', 'json', 'yaml', 'yml', 'xml', 'html',
  'css', 'js', 'ts', 'jsx', 'tsx', 'dart', 'java', 'kt', 'kts', 'gradle',
  'py', 'rb', 'go', 'rs', 'c', 'h', 'cpp', 'hpp', 'cs', 'sh', 'bat', 'ps1',
  'sql', 'toml', 'ini', 'cfg', 'properties', 'log', 'env', 'swift', 'php',
];

bool _isTextLikeFileName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return false;
  return _textLikeExtensions.contains(name.substring(dot + 1).toLowerCase());
}

Future<String?> _defaultPickGalleryImage() async {
  final file = await ImagePicker().pickImage(
    source: ImageSource.gallery,
    maxWidth: 1600,
    maxHeight: 1600,
    imageQuality: 80,
  );
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  return 'data:image/jpeg;base64,${base64Encode(bytes)}';
}

/// Thrown by the default text-file picker when the user dismisses the
/// system dialog — distinct from a genuine read failure.
class _FilePickCancelled implements Exception {}

Future<TextFileAttachment> _defaultPickTextFile() async {
  const typeGroup = XTypeGroup(
    label: '文本与代码',
    extensions: _textLikeExtensions,
  );
  final file = await openFile(acceptedTypeGroups: [typeGroup]);
  if (file == null) {
    throw _FilePickCancelled();
  }
  if (!_isTextLikeFileName(file.name)) {
    throw StateError('暂只支持文本与代码文件(PDF 等后续版本支持)');
  }
  final bytes = await file.readAsBytes();
  if (bytes.length > _maxTextFileBytes) {
    throw StateError('文件过大:文本附件上限 200KB');
  }
  return TextFileAttachment(
    name: file.name,
    content: utf8.decode(bytes, allowMalformed: true),
  );
}

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
  final _pendingImages = <String>[];
  final _pendingFiles = <TextFileAttachment>[];
  bool _approvalSheetOpen = false;

  @override
  void dispose() {
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send([String? preset]) {
    final text = (preset ?? _composer.text).trim();
    if (text.isEmpty && _pendingImages.isEmpty && _pendingFiles.isEmpty) {
      return;
    }
    final images = [..._pendingImages];
    final files = [..._pendingFiles];
    _composer.clear();
    setState(() {
      _pendingImages.clear();
      _pendingFiles.clear();
    });
    ref
        .read(chatSessionProvider.notifier)
        .send(text, images: images, files: files);
  }

  Future<void> _attachImage() async {
    if (_pendingImages.length >= _maxImagesPerMessage) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('一条消息最多带 4 张图片')),
      );
      return;
    }
    final dataUrl = await pickGalleryImage();
    if (dataUrl == null) return;
    setState(() => _pendingImages.add(dataUrl));
  }

  Future<void> _attachFile() async {
    if (_pendingFiles.length >= _maxFilesPerMessage) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('一条消息最多带 4 个文件')),
      );
      return;
    }
    try {
      final file = await pickTextFile();
      setState(() => _pendingFiles.add(file));
    } on _FilePickCancelled {
      return;
    } on StateError catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('无法读取该文件')),
      );
    }
  }

  void _showAttachSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: AppSpacing.sm),
            ListTile(
              leading: const Icon(Icons.add_photo_alternate_outlined),
              title: const Text('添加图片(相册)'),
              onTap: () {
                Navigator.pop(sheetContext);
                _attachImage();
              },
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('添加文件(文本/代码,≤200KB)'),
              onTap: () {
                Navigator.pop(sheetContext);
                _attachFile();
              },
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
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

  String? _conversationTitle(AsyncValue<SettingsStore> storeAsync, String id) {
    return storeAsync.maybeWhen(
      data: (store) {
        // The summary is written only after the task persists, so a running
        // conversation may legitimately be absent from the list yet.
        final summaries = store.loadConversations();
        for (final summary in summaries) {
          if (summary.id == id) return summary.title;
        }
        return null;
      },
      orElse: () => null,
    );
  }

  void _startNewConversation(BuildContext context, WidgetRef ref) {
    final ok = ref.read(chatSessionProvider.notifier).newConversation();
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      duration: const Duration(seconds: 2),
      content: Text(ok ? '已开启新对话' : '任务进行中,请先停止当前任务'),
    ));
  }

  void _showSessionSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _SessionSheet(),
    );
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
            _Header(
              demoMode: demoMode,
              conversationTitle: session.conversationId == null
                  ? null
                  : _conversationTitle(storeAsync, session.conversationId!),
              onTitleTap: () => _showSessionSheet(context),
              onNewConversation: () => _startNewConversation(context, ref),
            ),
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
              pendingImages: List.unmodifiable(_pendingImages),
              pendingFiles: List.unmodifiable(_pendingFiles),
              onAttach: session.isBusy &&
                      session.phase != SessionPhase.waitingApproval
                  ? null
                  : _showAttachSheet,
              onRemoveImage: (index) =>
                  setState(() => _pendingImages.removeAt(index)),
              onRemoveFile: (index) =>
                  setState(() => _pendingFiles.removeAt(index)),
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
  const _Header({
    required this.demoMode,
    this.conversationTitle,
    this.onTitleTap,
    this.onNewConversation,
  });

  final bool demoMode;
  final String? conversationTitle;
  final VoidCallback? onTitleTap;
  final VoidCallback? onNewConversation;

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
            child: InkWell(
              onTap: onTitleTap,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Shelly',
                        style: TextStyle(
                            fontSize: 16.5, fontWeight: FontWeight.w700)),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            conversationTitle ??
                                (demoMode ? '演示模式' : '新对话'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12,
                                color: semantic.textTertiary),
                          ),
                        ),
                        Icon(Icons.expand_more,
                            size: 14, color: semantic.textTertiary),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          _ModelChip(),
          IconButton(
            tooltip: '会话列表',
            onPressed: onTitleTap,
            icon: Icon(Icons.toc_outlined,
                size: 21, color: semantic.textSecondary),
          ),
          IconButton(
            tooltip: '开启新对话',
            onPressed: onNewConversation,
            icon: Icon(Icons.add_comment_outlined,
                size: 21, color: semantic.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// Compact model indicator; tapping opens the model picker sheet. Shows
/// the active model id, or 选择模型 while no endpoint is configured.
class _ModelChip extends ConsumerWidget {
  const _ModelChip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(settingsStoreProvider).maybeWhen(
          data: (store) => store.modelConfig,
          orElse: () => const ModelConfig(),
        );
    final label = config.isComplete ? config.model : '选择模型';
    return GestureDetector(
      onTap: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => const ModelPickerSheet(),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm, vertical: 5),
        decoration: BoxDecoration(
          color: AppColors.brandViolet.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.bolt_rounded,
                size: 13, color: AppColors.brandViolet),
            const SizedBox(width: 3),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 110),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.brandViolet),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet listing recent conversations: switch by tapping, manage
/// (rename / pin / delete) through each row's overflow menu.
class _SessionSheet extends ConsumerWidget {
  const _SessionSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final storeAsync = ref.watch(settingsStoreProvider);
    final conversations = storeAsync.maybeWhen(
      data: (store) => sortConversations(store.loadConversations()).take(20).toList(),
      orElse: () => const <ConversationSummary>[],
    );
    final currentId = ref.watch(chatSessionProvider).conversationId;
    final busy = ref.watch(chatSessionProvider).isBusy;

    return Container(
      constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.72),
      decoration: BoxDecoration(
        color: semantic.card,
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: AppSpacing.sm),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: semantic.border,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.sm, AppSpacing.sm, AppSpacing.xs),
            child: Row(
              children: [
                Text('会话',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: semantic.textPrimary)),
                const Spacer(),
                TextButton.icon(
                  onPressed: busy
                      ? null
                      : () {
                          ref.read(chatSessionProvider.notifier).newConversation();
                          Navigator.of(context).pop();
                        },
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('新会话', style: TextStyle(fontSize: 13)),
                ),
              ],
            ),
          ),
          Flexible(
            child: conversations.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(AppSpacing.xl),
                    child: Text('发送第一条消息后会话会出现在这里',
                        style: TextStyle(
                            fontSize: 12.5, color: semantic.textTertiary)),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(
                        AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
                    itemCount: conversations.length,
                    itemBuilder: (context, index) {
                      final conversation = conversations[index];
                      final isCurrent = conversation.id == currentId;
                      return Container(
                        margin: const EdgeInsets.only(bottom: AppSpacing.xs),
                        decoration: BoxDecoration(
                          color: isCurrent
                              ? AppColors.brandBlue.withValues(alpha: 0.10)
                              : semantic.background,
                          borderRadius: BorderRadius.circular(AppRadius.md),
                        ),
                        child: Material(
                          type: MaterialType.transparency,
                          child: ListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.md),
                          leading: isCurrent
                              ? const Icon(Icons.check_circle_outline,
                                  size: 18, color: AppColors.brandBlue)
                              : Icon(Icons.forum_outlined,
                                  size: 18, color: semantic.textTertiary),
                          title: Text(
                            (conversation.pinned ? '📌 ' : '') +
                                conversation.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: isCurrent
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: semantic.textPrimary),
                          ),
                          subtitle: Text(
                            '${conversation.messageCount} 条消息 · ${_relativeTime(conversation.updatedAt)}',
                            style: TextStyle(
                                fontSize: 11, color: semantic.textTertiary),
                          ),
                          trailing: PopupMenuButton<String>(
                            itemBuilder: (menuContext) => [
                              const PopupMenuItem(
                                  value: 'rename', child: Text('重命名')),
                              PopupMenuItem(
                                  value: 'pin',
                                  child: Text(conversation.pinned
                                      ? '取消置顶'
                                      : '置顶')),
                              const PopupMenuItem(
                                  value: 'delete', child: Text('删除')),
                            ],
                            onSelected: (action) => _handleAction(
                              context,
                              ref,
                              action,
                              conversation,
                            ),
                          ),
                          onTap: () {
                            if (busy) {
                              Navigator.of(context).pop();
                              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                                const SnackBar(
                                    content: Text('任务进行中,请先停止当前任务')),
                              );
                              return;
                            }
                            if (!isCurrent) {
                              ref
                                  .read(chatSessionProvider.notifier)
                                  .switchTo(conversation.id);
                            }
                            Navigator.of(context).pop();
                          },
                        ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleAction(
    BuildContext context,
    WidgetRef ref,
    String action,
    ConversationSummary conversation,
  ) async {
    final store = ref.read(settingsStoreProvider).valueOrNull;
    if (store == null) return;
    switch (action) {
      case 'rename':
        await renameConversationDialog(context, ref, store, conversation);
        break;
      case 'pin':
        await toggleConversationPin(ref, store, conversation);
        break;
      case 'delete':
        await deleteConversationDialog(context, ref, store, conversation);
        break;
    }
  }
}

String _relativeTime(DateTime time) {
  final difference = DateTime.now().difference(time);
  if (difference.inMinutes < 1) return '刚刚';
  if (difference.inHours < 1) return '${difference.inMinutes} 分钟前';
  if (difference.inDays < 1) return '${difference.inHours} 小时前';
  if (difference.inDays < 30) return '${difference.inDays} 天前';
  return '${time.year}/${time.month}/${time.day}';
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
          UserEntry() => _UserBubble(
              text: entry.text,
              images: entry.images,
              fileNames: entry.fileNames,
            ),
          AssistantEntry() => _AssistantMessage(entry: entry),
          ToolEntry() => ToolCard(
              entry: entry,
              isPlugin: pluginToolNames.contains(entry.call.name),
            ),
          ErrorEntry() => _ErrorBubble(text: entry.text),
          NoticeEntry() => _NoticePill(text: entry.text),
        };
      },
    );
  }
}

class _NoticePill extends StatelessWidget {
  const _NoticePill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: 6),
        decoration: BoxDecoration(
          color: semantic.card,
          borderRadius: BorderRadius.circular(AppRadius.xl),
          border: Border.all(color: semantic.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.compress_rounded, size: 13, color: semantic.textTertiary),
            const SizedBox(width: AppSpacing.xs),
            Flexible(
              child: Text(text,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: semantic.textTertiary)),
            ),
          ],
        ),
      ),
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({
    required this.text,
    this.images = const [],
    this.fileNames = const [],
  });
  final String text;
  final List<String> images;
  final List<String> fileNames;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final bubble = Container(
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
    );
    return Align(
      alignment: Alignment.centerRight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (fileNames.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  for (final name in fileNames)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm, vertical: 4),
                      decoration: BoxDecoration(
                        color: semantic.card,
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        border: Border.all(color: semantic.border),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.description_outlined,
                              size: 13, color: semantic.textSecondary),
                          const SizedBox(width: 4),
                          Text(name,
                              style: TextStyle(
                                  fontSize: 11.5,
                                  color: semantic.textSecondary)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          for (final url in images)
            Container(
              margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.78,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.lg),
                child: Image.memory(
                  base64Decode(url.split(',').last),
                  height: 180,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => Container(
                    height: 120,
                    padding: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      color: semantic.card,
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.broken_image_outlined,
                          size: 18, color: semantic.textTertiary),
                      const SizedBox(width: AppSpacing.xs),
                      Text('图片无法显示',
                          style: TextStyle(
                              fontSize: 12, color: semantic.textTertiary)),
                    ]),
                  ),
                ),
              ),
            ),
          if (text.isNotEmpty)
            Container(
              margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.78,
              ),
              child: bubble,
            ),
        ],
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
    required this.pendingImages,
    required this.pendingFiles,
    required this.onAttach,
    required this.onRemoveImage,
    required this.onRemoveFile,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final bool busy;
  final bool waitingApproval;
  final int inputTokens;
  final int outputTokens;
  final List<String> pendingImages;
  final List<TextFileAttachment> pendingFiles;
  final VoidCallback? onAttach;
  final void Function(int index) onRemoveImage;
  final void Function(int index) onRemoveFile;
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
          if (pendingFiles.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: [
                  for (var i = 0; i < pendingFiles.length; i += 1)
                    InputChip(
                      avatar: const Icon(Icons.description_outlined, size: 16),
                      label: Text(pendingFiles[i].name),
                      onDeleted: () => onRemoveFile(i),
                      labelStyle: const TextStyle(fontSize: 12),
                    ),
                ],
              ),
            ),
          if (pendingImages.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: SizedBox(
                height: 76,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: pendingImages.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(width: AppSpacing.sm),
                  itemBuilder: (context, index) => Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        child: Image.memory(
                          base64Decode(pendingImages[index].split(',').last),
                          width: 76,
                          height: 76,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                        ),
                      ),
                      Positioned(
                        top: 2,
                        right: 2,
                        child: _RemoveImageButton(onRemove: () => onRemoveImage(index)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                onPressed: onAttach,
                tooltip: '添加图片或文件',
                icon: Icon(Icons.add_circle_outline_rounded,
                    size: 24, color: semantic.textSecondary),
              ),
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

class _RemoveImageButton extends StatelessWidget {
  const _RemoveImageButton({required this.onRemove});

  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onRemove,
      child: Container(
        width: 20,
        height: 20,
        decoration: const BoxDecoration(
          color: Colors.black54,
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.close_rounded, size: 14, color: Colors.white),
      ),
    );
  }
}

class _StopButton extends StatelessWidget {
  const _StopButton({required this.onStop});

  final VoidCallback onStop;  @override
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
