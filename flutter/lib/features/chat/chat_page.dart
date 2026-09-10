import 'dart:async';

import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../../shelly_facade.dart';
import '../../design/components/buttons.dart';
import '../../design/components/gradient_avatar.dart';
import '../../design/components/markdown_text.dart';
import '../../design/components/motion.dart';
import 'in_chat_search.dart';
import '../../design/components/skeleton.dart';
import '../../design/components/tool_card.dart';
import '../../design/tokens.dart';
import '../../platform/platform_workspace.dart' show ResilientWorkspace;
import '../../platform/speech.dart';
import '../../platform/shared_intent.dart';
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

/// Injectable speech transcriber; tests swap this out because real
/// recognition needs the platform speech channel and mic permission.
SpeechTranscriber Function() createSpeechTranscriber =
    PlatformSpeechTranscriber.new;

void resetSpeechTranscriber() =>
    createSpeechTranscriber = PlatformSpeechTranscriber.new;

/// Injectable system share sheet; widget tests capture the payload instead
/// of opening the platform dialog.
Future<void> Function(String text, {String? title}) shareConversationText =
    _defaultShareConversationText;

void resetShareConversation() =>
    shareConversationText = _defaultShareConversationText;

/// Injectable TTS engine; widget tests swap this out because real
/// synthesis needs the platform TTS channel.
TtsService Function() createTtsService = FlutterTtsService.new;

void resetTtsService() => createTtsService = FlutterTtsService.new;

Future<void> _defaultShareConversationText(String text, {String? title}) async {
  await SharePlus.instance.share(ShareParams(text: text, title: title));
}

const _textLikeExtensions = [
  'txt',
  'md',
  'markdown',
  'csv',
  'tsv',
  'json',
  'yaml',
  'yml',
  'xml',
  'html',
  'css',
  'js',
  'ts',
  'jsx',
  'tsx',
  'dart',
  'java',
  'kt',
  'kts',
  'gradle',
  'py',
  'rb',
  'go',
  'rs',
  'c',
  'h',
  'cpp',
  'hpp',
  'cs',
  'sh',
  'bat',
  'ps1',
  'sql',
  'toml',
  'ini',
  'cfg',
  'properties',
  'log',
  'env',
  'swift',
  'php',
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
  const typeGroup = XTypeGroup(label: '文本与代码', extensions: _textLikeExtensions);
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
  SpeechTranscriber? _speech;
  bool _dictating = false;
  bool _dictateCancelled = false;
  String _dictated = '';
  TtsService? _tts;
  String? _speakingEntryId;
  // PHASE 54: in-conversation search state.
  bool _searchOpen = false;
  InChatSearchState _search = const InChatSearchState();
  int? _highlightEntryIndex;
  Timer? _highlightTimer;

  /// Hold-to-talk: recognition starts on press-down and the settled
  /// transcript is appended to the composer on release.
  Future<void> _startDictation() async {
    if (_dictating) return;
    final transcriber = _speech ??= createSpeechTranscriber();
    _dictateCancelled = false;
    bool ready;
    try {
      ready = await transcriber.initialize().timeout(
        const Duration(seconds: 3),
      );
    } catch (_) {
      ready = false;
    }
    if (!mounted) return;
    if (!ready) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('语音输入不可用(设备不支持或未授权麦克风)')));
      return;
    }
    if (_dictateCancelled) return;
    _dictated = '';
    setState(() => _dictating = true);
    try {
      await transcriber.listen(
        localeId: 'zh_CN',
        onResult: (text, isFinal) {
          if (isFinal) _dictated = text;
        },
      );
    } catch (_) {
      if (mounted) setState(() => _dictating = false);
    }
  }

  Future<void> _stopDictation() async {
    if (!_dictating) {
      // Released before recognition finished initializing — skip listening.
      _dictateCancelled = true;
      return;
    }
    setState(() => _dictating = false);
    try {
      await _speech?.stop().timeout(const Duration(milliseconds: 800));
    } catch (_) {
      // Recognition cleanup is best-effort; the transcript we have is used.
    }
    final text = _dictated.trim();
    if (text.isEmpty) return;
    final current = _composer.text;
    _composer.text = current.isEmpty ? text : '$current $text';
  }

  Future<void> _shareConversation() async {
    final session = ref.read(chatSessionProvider);
    if (session.entries.isEmpty) return;
    final title = session.conversationId == null
        ? null
        : _conversationTitle(
            ref.read(settingsStoreProvider),
            session.conversationId!,
          );
    final markdown = exportConversationMarkdown(
      title: title,
      entries: session.entries,
    );
    await shareConversationText(markdown, title: title);
  }

  StreamSubscription<String>? _sharedTextSub;

  @override
  void initState() {
    super.initState();
    // Text shared from other apps lands in the composer, ready to send.
    _sharedTextSub = sharedTextStream().listen(
      _takeSharedText,
      onError: (_) {},
    );
    initialSharedText().then(_takeSharedText);
  }

  void _takeSharedText(String? text) {
    final trimmed = text?.trim() ?? '';
    if (trimmed.isEmpty || !mounted) return;
    final current = _composer.text;
    _composer.text = current.isEmpty ? trimmed : '$current\n$trimmed';
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('已把分享内容填入输入框,确认后发送')),
    );
  }

  @override
  void dispose() {
    _sharedTextSub?.cancel();
    unawaited(_tts?.stop());
    _highlightTimer?.cancel();
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Toggles the voice readout of one assistant reply: tapping the speaker
  /// starts speaking (or, on the speaking row, stops early). Only rendered
  /// while the settings TTS toggle is on.
  Future<void> _toggleSpeak(AssistantEntry entry) async {
    final tts = _tts ??= createTtsService();
    if (_speakingEntryId == entry.id) {
      setState(() => _speakingEntryId = null);
      try {
        await tts.stop();
      } catch (_) {
        // Stopping is best-effort; the icon already flipped back.
      }
      return;
    }
    setState(() => _speakingEntryId = entry.id);
    try {
      await tts.speak(ttsPlainText(entry.text));
    } catch (_) {
      // A missing platform channel must never break the transcript.
    }
    if (mounted && _speakingEntryId == entry.id) {
      setState(() => _speakingEntryId = null);
    }
  }

  void _send([String? preset]) {
    final text = (preset ?? _composer.text).trim();
    if (text.isEmpty && _pendingImages.isEmpty && _pendingFiles.isEmpty) {
      return;
    }
    // PHASE 51: while a task runs, a text send parks the message in the
    // steering queue (放入队列) instead of being dead — the controller
    // auto-sends it when the task completes. Attachments cannot be queued,
    // so they stay pending for the next real send.
    if (ref.read(chatSessionProvider).isBusy) {
      if (text.isEmpty) return;
      ref.read(chatSessionProvider.notifier).send(text);
      _composer.clear();
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
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('一条消息最多带 4 张图片')));
      return;
    }
    final dataUrl = await pickGalleryImage();
    if (dataUrl == null) return;
    setState(() => _pendingImages.add(dataUrl));
  }

  Future<void> _attachFile() async {
    if (_pendingFiles.length >= _maxFilesPerMessage) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('一条消息最多带 4 个文件')));
      return;
    }
    try {
      final file = await pickTextFile();
      setState(() => _pendingFiles.add(file));
    } on _FilePickCancelled {
      return;
    } on StateError catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('无法读取该文件')));
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

  /// PHASE 50: 编辑并重发 — long-pressing the last user bubble opens the
  /// management sheet; saving re-runs the turn with the edited text.
  void _showEditResendSheet(UserEntry entry) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _EditResendSheet(
        initialText: entry.text,
        onSubmit: (text) {
          final ok =
              ref.read(chatSessionProvider.notifier).editAndResend(text);
          if (!ok) {
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              const SnackBar(content: Text('任务进行中,请先停止当前任务')),
            );
          }
        },
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
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(ok ? '已开启新对话' : '任务进行中,请先停止当前任务'),
      ),
    );
  }

  void _showSessionSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _SessionSheet(),
    );
  }

  void _toggleSearch() {
    setState(() {
      if (_searchOpen) {
        _searchOpen = false;
        _search = const InChatSearchState();
        _highlightEntryIndex = null;
        _highlightTimer?.cancel();
      } else {
        _searchOpen = true;
      }
    });
  }

  void _onSearchQueryChanged(String query) {
    final matches = computeMatches(sessionEntries(), query);
    setState(() {
      _search = _search.copyWith(query: query, matches: matches, currentIndex: 0);
      _highlightEntryIndex = matches.isEmpty ? null : matches.first.entryIndex;
    });
  }

  List<ChatEntry> sessionEntries() => ref.read(chatSessionProvider).entries;

  void _navigateSearch(int step) {
    if (!_search.hasMatches) return;
    var next = (_search.currentIndex + step) % _search.matches.length;
    if (next < 0) next += _search.matches.length;
    setState(() {
      _search = _search.copyWith(currentIndex: next);
      _highlightEntryIndex = _search.matches[next].entryIndex;
    });
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _highlightEntryIndex = null);
    });
    _scrollToEntry(_highlightEntryIndex!);
  }

  /// Best-effort scroll: jumps the transcript ListView to a fractional
  /// position matching the entry's share of the transcript.
  void _scrollToEntry(int entryIndex) {
    final total = ref.read(chatSessionProvider).entries.length;
    if (total == 0 || !_scroll.hasClients) return;
    final target = (_scroll.position.maxScrollExtent * (entryIndex / total))
        .clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.jumpTo(target);
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
    final workspaceReady =
        ref.watch(workspaceAuthorizedProvider).asData?.value ?? true;

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
              onShare: session.entries.isEmpty
                  ? null
                  : () => unawaited(_shareConversation()),
              onSearch: session.entries.isEmpty ? null : _toggleSearch,
            ),
            if (!workspaceReady)
              _WorkspaceBanner(onPick: pickWorkspaceDirectory),
            if (demoMode) _DemoBanner(onTap: () => _send('演示补丁')),
            if (_searchOpen)
              InChatSearchBar(
                state: _search,
                onQueryChanged: _onSearchQueryChanged,
                onNext: () => _navigateSearch(1),
                onPrevious: () => _navigateSearch(-1),
                onClose: _toggleSearch,
              ),
            Expanded(
              child: session.entries.isEmpty
                  ? _Greeting(onSuggestion: _send)
                  : _Transcript(
                      entries: session.entries,
                      controller: _scroll,
                      ttsEnabled: storeAsync.maybeWhen(
                        data: (store) => store.ttsEnabled,
                        orElse: () => false,
                      ),
                      speakingEntryId: _speakingEntryId,
                      onToggleSpeak: _toggleSpeak,
                      onRegenerate: session.isBusy
                          ? null
                          : () {
                              final ok = ref
                                  .read(chatSessionProvider.notifier)
                                  .regenerateLast();
                              if (!ok) {
                                ScaffoldMessenger.maybeOf(context)
                                    ?.showSnackBar(
                                  const SnackBar(
                                      content: Text('没有可重新生成的回复')),
                                );
                              }
                            },
                      onEditResend: session.isBusy
                          ? null
                          : (entry) => _showEditResendSheet(entry),
                      highlightEntryIndex: _highlightEntryIndex,
                      pluginToolNames: ref
                          .watch(dshToolsProvider)
                          .specs
                          .map((spec) => spec.name)
                          .toSet(),
                    ),
            ),
            // PHASE 52: slim context-usage meter between the transcript and
            // the queued-chips/composer area. Visible only once a round has
            // consumed input tokens; a fresh conversation hides it again.
            if (session.inputTokens > 0)
              _ContextMeter(inputTokens: session.inputTokens),
            _Composer(
              controller: _composer,
              busy: session.isBusy,
              waitingApproval: session.phase == SessionPhase.waitingApproval,
              inputTokens: session.inputTokens,
              outputTokens: session.outputTokens,
              queuedMessages: session.queuedMessages,
              onRemoveQueued: (index) => ref
                  .read(chatSessionProvider.notifier)
                  .removeQueuedMessage(index),
              pendingImages: List.unmodifiable(_pendingImages),
              pendingFiles: List.unmodifiable(_pendingFiles),
              onAttach:
                  session.isBusy &&
                      session.phase != SessionPhase.waitingApproval
                  ? null
                  : _showAttachSheet,
              onRemoveImage: (index) =>
                  setState(() => _pendingImages.removeAt(index)),
              onRemoveFile: (index) =>
                  setState(() => _pendingFiles.removeAt(index)),
              onSend: _send,
              onStop: () => ref.read(chatSessionProvider.notifier).cancel(),
              dictating: _dictating,
              onDictateStart: _startDictation,
              onDictateStop: _stopDictation,
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
    this.onShare,
    this.onSearch,
  });

  final bool demoMode;
  final String? conversationTitle;
  final VoidCallback? onTitleTap;
  final VoidCallback? onNewConversation;
  final VoidCallback? onShare;
  final VoidCallback? onSearch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
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
                    const Text(
                      'Shelly',
                      style: TextStyle(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            conversationTitle ?? (demoMode ? '演示模式' : '新对话'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: semantic.textTertiary,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.expand_more,
                          size: 14,
                          color: semantic.textTertiary,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          _ModelChip(),
          if (onShare != null)
            IconButton(
              tooltip: '分享对话',
              onPressed: onShare,
              icon: Icon(
                Icons.ios_share_rounded,
                size: 19,
                color: semantic.textSecondary,
              ),
            ),
          if (onSearch != null)
            IconButton(
              tooltip: '在会话中搜索',
              onPressed: onSearch,
              icon: Icon(
                Icons.search_rounded,
                size: 20,
                color: semantic.textSecondary,
              ),
            ),
          IconButton(
            tooltip: '会话列表',
            onPressed: onTitleTap,
            visualDensity: VisualDensity.comfortable,
            icon: Icon(
              Icons.toc_outlined,
              size: 21,
              color: semantic.textSecondary,
            ),
          ),
          IconButton(
            tooltip: '开启新对话',
            onPressed: onNewConversation,
            visualDensity: VisualDensity.comfortable,
            icon: Icon(
              Icons.add_comment_outlined,
              size: 21,
              color: semantic.textSecondary,
            ),
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
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final config = ref
        .watch(settingsStoreProvider)
        .maybeWhen(
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
        // 36px tall: compact chip look but an acceptable touch target.
        constraints: const BoxConstraints(minHeight: 36),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: semantic.floating,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.bolt_rounded,
              size: 13,
              color: semantic.textSecondary,
            ),
            const SizedBox(width: 3),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 110),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: semantic.textSecondary,
                ),
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
      data: (store) =>
          sortConversations(store.loadConversations()).take(20).toList(),
      orElse: () => const <ConversationSummary>[],
    );
    final currentId = ref.watch(chatSessionProvider).conversationId;
    final busy = ref.watch(chatSessionProvider).isBusy;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.72,
      ),
      decoration: BoxDecoration(
        color: semantic.card,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.xl),
        ),
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
              AppSpacing.lg,
              AppSpacing.sm,
              AppSpacing.sm,
              AppSpacing.xs,
            ),
            child: Row(
              children: [
                Text(
                  '会话',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: semantic.textPrimary,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: busy
                      ? null
                      : () {
                          ref
                              .read(chatSessionProvider.notifier)
                              .newConversation();
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
                    child: Text(
                      '发送第一条消息后会话会出现在这里',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: semantic.textTertiary,
                      ),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg,
                      0,
                      AppSpacing.lg,
                      AppSpacing.lg,
                    ),
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
                              horizontal: AppSpacing.md,
                            ),
                            leading: isCurrent
                                ? const Icon(
                                    Icons.check_circle_outline,
                                    size: 18,
                                    color: AppColors.brandBlue,
                                  )
                                : Icon(
                                    Icons.forum_outlined,
                                    size: 18,
                                    color: semantic.textTertiary,
                                  ),
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
                                color: semantic.textPrimary,
                              ),
                            ),
                            subtitle: Text(
                              '${conversation.messageCount} 条消息 · ${_relativeTime(conversation.updatedAt)}',
                              style: TextStyle(
                                fontSize: 11,
                                color: semantic.textTertiary,
                              ),
                            ),
                            trailing: PopupMenuButton<String>(
                              itemBuilder: (menuContext) => [
                                const PopupMenuItem(
                                  value: 'rename',
                                  child: Text('重命名'),
                                ),
                                PopupMenuItem(
                                  value: 'pin',
                                  child: Text(
                                    conversation.pinned ? '取消置顶' : '置顶',
                                  ),
                                ),
                                const PopupMenuItem(
                                  value: 'delete',
                                  child: Text('删除'),
                                ),
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
                                ScaffoldMessenger.maybeOf(context)
                                    ?.showSnackBar(
                                      const SnackBar(
                                        content: Text('任务进行中,请先停止当前任务'),
                                      ),
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
        AppSpacing.lg,
        AppSpacing.xs,
        AppSpacing.lg,
        0,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.folder_off_outlined,
              size: 15,
              color: AppColors.warning,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                '演示沙箱:文件改动不会落盘,选择目录后即可真实读写',
                style: TextStyle(fontSize: 12, color: semantic.textSecondary),
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
                  color: AppColors.warning,
                ),
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
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.science_outlined,
                  size: 15,
                  color: AppColors.brandBlue,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    '演示模式:未配置模型接口,点击体验工具审批流程',
                    style: TextStyle(
                      fontSize: 12,
                      color: semantic.textSecondary,
                    ),
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  size: 15,
                  color: semantic.textTertiary,
                ),
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
          Text(
            '你好,我是 Shelly',
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '把任务交给我,我会拆解步骤、调用工具,\n并在关键操作前征求你的同意。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              height: 1.6,
              color: semantic.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          ..._suggestions.map(
            (s) => Padding(
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
                          child: Icon(
                            s.$1,
                            size: 17,
                            color: AppColors.brandBlue,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                s.$2,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                s.$3,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: semantic.textTertiary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Transcript extends StatelessWidget {
  const _Transcript({
    required this.entries,
    required this.controller,
    this.ttsEnabled = false,
    this.speakingEntryId,
    this.onToggleSpeak,
    this.onRegenerate,
    this.onEditResend,
    this.pluginToolNames = const {},
    this.highlightEntryIndex,
  });

  final List<ChatEntry> entries;
  final ScrollController controller;
  final int? highlightEntryIndex;

  /// When the settings TTS toggle is on, finished assistant replies grow a
  /// speaker button that reads the message's plain text aloud.
  final bool ttsEnabled;
  final String? speakingEntryId;
  final Future<void> Function(AssistantEntry entry)? onToggleSpeak;

  /// PHASE 50: re-runs the conversation from the last user message. Offered
  /// on the LAST assistant entry only, via a small refresh icon.
  final VoidCallback? onRegenerate;

  /// PHASE 50: opens the 编辑并重发 sheet for the LAST user bubble.
  final void Function(UserEntry entry)? onEditResend;

  /// DSH tool names currently registered; entries hitting these render with
  /// the 插件 badge so users can tell plugin calls from core tool calls.
  final Set<String> pluginToolNames;

  @override
  Widget build(BuildContext context) {
    final lastAssistantIndex = entries.lastIndexWhere((e) => e is AssistantEntry);
    final lastUserIndex = entries.lastIndexWhere((e) => e is UserEntry);
    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final highlighted = highlightEntryIndex == index;
        Widget row = switch (entry) {
          UserEntry() => _UserBubble(
            text: entry.text,
            images: entry.images,
            fileNames: entry.fileNames,
            onLongPress: onEditResend == null || index != lastUserIndex
                ? null
                : () => onEditResend!(entry),
          ),
          AssistantEntry() => _AssistantMessage(
            entry: entry,
            ttsEnabled: ttsEnabled,
            speaking: speakingEntryId == entry.id,
            onToggleSpeak: onToggleSpeak == null
                ? null
                : () => onToggleSpeak!(entry),
            onRegenerate:
                onRegenerate == null || index != lastAssistantIndex
                    ? null
                    : onRegenerate,
          ),
          ToolEntry() => ToolCard(
            entry: entry,
            isPlugin: pluginToolNames.contains(entry.call.name),
          ),
          ErrorEntry() => _ErrorBubble(text: entry.text),
          NoticeEntry() => _NoticePill(text: entry.text),
        };
        if (!highlighted) return row;
        return Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: Theme.of(context)
                      .extension<AppSemanticColors>()!
                      .warning
                      .withValues(alpha: 0.6),
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            child: row,
          ),
        );
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
          horizontal: AppSpacing.md,
          vertical: 6,
        ),
        decoration: BoxDecoration(
          color: semantic.card,
          borderRadius: BorderRadius.circular(AppRadius.xl),
          border: Border.all(color: semantic.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.compress_rounded,
              size: 13,
              color: semantic.textTertiary,
            ),
            const SizedBox(width: AppSpacing.xs),
            Flexible(
              child: Text(
                text,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: semantic.textTertiary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Conversation images arrive either as inline data URLs (fresh send) or
/// on-disk file paths (restored from a checkpoint).
ImageProvider _userImageProvider(String source) {
  if (source.startsWith('data:')) {
    return MemoryImage(base64Decode(source.split(',').last));
  }
  return FileImage(File(source));
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({
    required this.text,
    this.images = const [],
    this.fileNames = const [],
    this.onLongPress,
  });
  final String text;
  final List<String> images;
  final List<String> fileNames;

  /// PHASE 50: opens the 编辑并重发 sheet. Only the LAST user bubble
  /// receives a non-null callback (regeneration truncates from there).
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    // PHASE 44: quiet white card with soft ambient shadow instead of the
    // saturated brand gradient — the canvas stays calm, user turns read as
    // "cards on gray".
    final bubble = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm + 2,
      ),
      decoration: BoxDecoration(
        color: semantic.card,
        borderRadius: BorderRadius.circular(AppRadius.lg)
            .copyWith(bottomRight: const Radius.circular(AppRadius.sm)),
        border: Border.all(color: semantic.border),
        boxShadow: semantic.cardShadow,
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 14.5,
          height: 1.5,
          color: semantic.textPrimary,
        ),
      ),
    );
    final textBubble = onLongPress == null
        ? bubble
        : GestureDetector(
            onLongPress: onLongPress,
            child: bubble,
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
                        horizontal: AppSpacing.sm,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: semantic.card,
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        border: Border.all(color: semantic.border),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.description_outlined,
                            size: 13,
                            color: semantic.textSecondary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            name,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: semantic.textSecondary,
                            ),
                          ),
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
                child: Image(
                  image: _userImageProvider(url),
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
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.broken_image_outlined,
                          size: 18,
                          color: semantic.textTertiary,
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        Text(
                          '图片无法显示',
                          style: TextStyle(
                            fontSize: 12,
                            color: semantic.textTertiary,
                          ),
                        ),
                      ],
                    ),
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
              child: textBubble,
            ),
        ],
      ),
    );
  }
}

class _AssistantMessage extends StatelessWidget {
  const _AssistantMessage({
    required this.entry,
    this.ttsEnabled = false,
    this.speaking = false,
    this.onToggleSpeak,
    this.onRegenerate,
  });

  final AssistantEntry entry;

  /// Whether the speaker button is rendered at all (settings toggle on).
  final bool ttsEnabled;

  /// Whether this row's readout is currently playing (stop icon shown).
  final bool speaking;
  final VoidCallback? onToggleSpeak;

  /// PHASE 50: re-runs the conversation from the last user message. Only
  /// the last assistant row receives a non-null callback; streaming rows
  /// never show the icon.
  final VoidCallback? onRegenerate;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final empty = entry.text.isEmpty && entry.streaming;
    final canSpeak = ttsEnabled && !entry.streaming && entry.text.trim().isNotEmpty;
    final canRegenerate =
        onRegenerate != null && !entry.streaming && entry.text.trim().isNotEmpty;
    // Motion discipline: message rows announce themselves with a soft
    // fade + rise; no stagger inside the transcript (it grows live).
    return FadeSlideIn(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (empty) ...[
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const TypingIndicator(),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    '正在思考…',
                    style: TextStyle(
                        fontSize: 12.5, color: semantic.textTertiary),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              const SkeletonMessageRow(),
            ] else if (entry.text.isEmpty)
              const TypingIndicator()
            else ...[
              MarkdownText(data: entry.text),
              if (entry.streaming) const _StreamingCursor(),
              if (canSpeak || canRegenerate)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (canSpeak)
                        IconButton(
                          tooltip: speaking ? '停止朗读' : '朗读回复',
                          onPressed: onToggleSpeak,
                          visualDensity: VisualDensity.compact,
                          padding:
                              const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                          constraints:
                              const BoxConstraints(minWidth: 32, minHeight: 32),
                          icon: Icon(
                            speaking
                                ? Icons.stop_circle_outlined
                                : Icons.volume_up_outlined,
                            size: 18,
                            color: speaking
                                ? AppColors.brandBlue
                                : semantic.textTertiary,
                          ),
                        ),
                      if (canRegenerate)
                        IconButton(
                          tooltip: '重新生成回复',
                          onPressed: onRegenerate,
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.sm),
                          constraints:
                              const BoxConstraints(minWidth: 32, minHeight: 32),
                          icon: Icon(
                            Icons.refresh_rounded,
                            size: 18,
                            color: semantic.textTertiary,
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// PHASE 50: 编辑并重发 sheet shown on long-pressing the last user bubble.
/// The field comes prefilled with the current message text (capped at 500
/// chars); saving replaces the turn's text and re-runs the conversation
/// from that point, mirroring the regenerate flow.
class _EditResendSheet extends StatefulWidget {
  const _EditResendSheet({
    required this.initialText,
    required this.onSubmit,
  });

  final String initialText;
  final void Function(String text) onSubmit;

  @override
  State<_EditResendSheet> createState() => _EditResendSheetState();
}

class _EditResendSheetState extends State<_EditResendSheet> {
  late final TextEditingController _field =
      TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _field.text.trim();
    if (text.isEmpty) return;
    Navigator.of(context).pop();
    widget.onSubmit(text);
  }

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: semantic.card,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppRadius.xl),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: semantic.border,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(
                  top: AppSpacing.sm,
                  bottom: AppSpacing.sm,
                ),
                child: Text(
                  '编辑并重发',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: semantic.textPrimary,
                  ),
                ),
              ),
              TextField(
                controller: _field,
                autofocus: true,
                maxLines: 4,
                minLines: 1,
                maxLength: 500,
                style: TextStyle(
                  fontSize: 14.5,
                  height: 1.4,
                  color: semantic.textPrimary,
                ),
                decoration: InputDecoration(
                  hintText: '修改这条消息后将重新发送',
                  hintStyle: TextStyle(
                    fontSize: 13.5,
                    color: semantic.textTertiary,
                  ),
                  filled: true,
                  fillColor: semantic.background,
                  counterStyle: TextStyle(
                    fontSize: 11,
                    color: semantic.textTertiary,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    borderSide: BorderSide(color: semantic.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    borderSide: BorderSide(color: semantic.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    borderSide: BorderSide(
                      color: semantic.textSecondary,
                      width: 1.2,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _field,
                    builder: (context, value, _) {
                      final enabled = value.text.trim().isNotEmpty;
                      return GradientButton(
                        label: '保存并重发',
                        onPressed: enabled ? _submit : null,
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
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
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: semantic.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// PHASE 52: compact context-usage meter above the queued-chips/composer
/// area. One static line: a 2px progress bar showing how much of the
/// 64000-token budget the last round consumed, plus a right-aligned
/// k-notation label. Zero interaction, no dismiss — it disappears entirely
/// while the conversation is empty (inputTokens == 0).
class _ContextMeter extends StatelessWidget {
  const _ContextMeter({required this.inputTokens});

  final int inputTokens;

  static final int _maxTokens = const AgentLimits().maxTokens;

  /// k-notation: one decimal below 10k (5.0k, 9.4k); at or above, whole
  /// values collapse to integer k (12k, 64k) while fractional ones keep a
  /// decimal (12.3k) — precision only where it carries information.
  static String _formatK(int tokens) {
    final value = tokens / 1000;
    if (value < 10 || value != value.roundToDouble()) {
      return '${value.toStringAsFixed(1)}k';
    }
    return '${value.round()}k';
  }

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final double fraction =
        (inputTokens / _maxTokens).clamp(0.0, 1.0).toDouble();
    final tint = fraction >= 0.9
        ? semantic.danger
        : fraction >= 0.7
            ? semantic.warning
            : semantic.textTertiary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        0,
      ),
      child: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 2,
                backgroundColor: semantic.border.withValues(alpha: 0.5),
                valueColor: AlwaysStoppedAnimation<Color>(tint),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            '上下文 ~${_formatK(inputTokens)} / ${_formatK(_maxTokens)}',
            style: TextStyle(fontSize: 11, color: semantic.textTertiary),
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
    required this.queuedMessages,
    required this.onRemoveQueued,
    required this.pendingImages,
    required this.pendingFiles,
    required this.onAttach,
    required this.onRemoveImage,
    required this.onRemoveFile,
    required this.onSend,
    required this.onStop,
    required this.dictating,
    required this.onDictateStart,
    required this.onDictateStop,
  });

  final TextEditingController controller;
  final bool busy;
  final bool waitingApproval;
  final int inputTokens;
  final int outputTokens;

  /// PHASE 51: steering messages parked while busy, rendered as dismissible
  /// chips between the transcript and the input row; X removes one.
  final List<String> queuedMessages;
  final void Function(int index) onRemoveQueued;

  final List<String> pendingImages;
  final List<TextFileAttachment> pendingFiles;
  final VoidCallback? onAttach;
  final void Function(int index) onRemoveImage;
  final void Function(int index) onRemoveFile;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final bool dictating;
  final VoidCallback onDictateStart;
  final VoidCallback onDictateStop;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    // PHASE 44: floating capsule composer on the gray canvas.
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      decoration: BoxDecoration(
        color: semantic.background,
        border: Border(top: BorderSide(color: semantic.border.withValues(alpha: 0.6))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (queuedMessages.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: _QueuedMessagesBar(
                messages: queuedMessages,
                onRemove: onRemoveQueued,
              ),
            ),
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
                        child: _RemoveImageButton(
                          onRemove: () => onRemoveImage(index),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _DictateButton(
                dictating: dictating,
                onStart: onDictateStart,
                onStop: onDictateStop,
              ),
              IconButton(
                onPressed: onAttach,
                tooltip: '添加图片或文件',
                icon: Icon(
                  Icons.add_circle_outline_rounded,
                  size: 24,
                  color: semantic.textSecondary,
                ),
              ),
              Expanded(
                child: TextField(
                  controller: controller,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  // PHASE 51: the composer stays alive while busy — submits
                  // park the text in the steering queue. Only the approval
                  // wait keeps keyboard submits off.
                  onSubmitted: waitingApproval ? null : (_) => onSend(),
                  style: const TextStyle(fontSize: 14.5, height: 1.4),
                  decoration: InputDecoration(
                    hintText: waitingApproval
                        ? '请在上方做出审批决定…'
                        : busy
                            ? '任务进行中,发送将中断并处理新消息…'
                            : '给 Shelly 发送消息…',
                    hintStyle: TextStyle(
                      fontSize: 13.5,
                      color: semantic.textTertiary,
                    ),
                    filled: true,
                    fillColor: semantic.card,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                      vertical: AppSpacing.sm + 4,
                    ),
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
                      borderSide: BorderSide(
                        color: semantic.textSecondary,
                        width: 1.2,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              if (busy) ...[
                // PHASE 51/54: while a task runs the send affordance stays
                // alive — with an empty queue it interrupts the running task
                // and the message re-sends on completion; with queued items
                // it parks at the end of the line.
                _QueueButton(onQueue: onSend),
                const SizedBox(width: AppSpacing.sm),
                _StopButton(onStop: onStop),
              ] else
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
                style: TextStyle(fontSize: 10.5, color: semantic.textTertiary),
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

/// Hold-to-talk microphone: press-and-hold records, release inserts the
/// settled transcript into the composer. Raw pointer events so even a quick
/// tap produces a matched start/stop pair.
class _DictateButton extends StatelessWidget {
  const _DictateButton({
    required this.dictating,
    required this.onStart,
    required this.onStop,
  });

  final bool dictating;
  final VoidCallback onStart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Listener(
      onPointerDown: (_) => onStart(),
      onPointerUp: (_) => onStop(),
      onPointerCancel: (_) => onStop(),
      child: IconButton(
        onPressed: null,
        tooltip: '按住说话',
        icon: Icon(
          dictating ? Icons.mic_rounded : Icons.mic_none_rounded,
          size: 24,
          color: dictating ? AppColors.brandBlue : semantic.textSecondary,
        ),
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

/// PHASE 51: the busy-state send affordance. Pressing it parks the composed
/// text in the steering queue (tooltip 放入队列) — the queued message
/// auto-sends when the running task completes. Brand-tinted so it reads as
/// the send button's alive twin next to [_StopButton].
class _QueueButton extends StatelessWidget {
  const _QueueButton({required this.onQueue});

  final VoidCallback onQueue;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '放入队列',
      child: GestureDetector(
        onTap: onQueue,
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: AppColors.brandBlue.withValues(alpha: 0.12),
            shape: BoxShape.circle,
            border: Border.all(
              color: AppColors.brandBlue.withValues(alpha: 0.35),
            ),
          ),
          child: const Icon(
            Icons.arrow_upward_rounded,
            size: 22,
            color: AppColors.brandBlue,
          ),
        ),
      ),
    );
  }
}

/// PHASE 51: steering messages parked while a task runs, shown between the
/// transcript and the composer. Each chip dismisses (X) its message so the
/// user can cancel a queued send before its auto-dispatch.
class _QueuedMessagesBar extends StatelessWidget {
  const _QueuedMessagesBar({required this.messages, required this.onRemove});

  final List<String> messages;
  final void Function(int index) onRemove;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      children: [
        for (var i = 0; i < messages.length; i += 1)
          InputChip(
            avatar: Icon(
              Icons.schedule_rounded,
              size: 14,
              color: AppColors.brandBlue,
            ),
            label: Text(
              messages[i],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: semantic.textSecondary,
              ),
            ),
            backgroundColor: semantic.card,
            side: BorderSide(color: semantic.border),
            deleteIconColor: semantic.textTertiary,
            onDeleted: () => onRemove(i),
          ),
      ],
    );
  }
}
