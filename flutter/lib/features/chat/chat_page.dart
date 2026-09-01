import 'package:flutter/material.dart';

import '../../design/components/buttons.dart';
import '../../design/components/gradient_avatar.dart';
import '../../design/tokens.dart';

/// Chat workbench. Stage 1 ships the visual frame: model chip in the top
/// bar, greeting with suggestion cards, and the fixed composer. Streaming,
/// tool cards and thinking timelines arrive with stage 4.
class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _composerController = TextEditingController();
  bool _hasInput = false;

  @override
  void initState() {
    super.initState();
    _composerController.addListener(() {
      final hasInput = _composerController.text.trim().isNotEmpty;
      if (hasInput != _hasInput) setState(() => _hasInput = hasInput);
    });
  }

  @override
  void dispose() {
    _composerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: AppSpacing.lg,
        title: Row(
          children: [
            const GradientAvatar(size: AvatarSize.small),
            const SizedBox(width: AppSpacing.sm + 2),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Shelly',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: semantic.textPrimary,
                    height: 1.1,
                  ),
                ),
                Text(
                  'Hermes Agent · 随时待命',
                  style: TextStyle(
                    fontSize: 11,
                    color: semantic.textTertiary,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '新对话',
            onPressed: () {},
            icon: const Icon(Icons.add_comment_outlined, size: 22),
          ),
          const SizedBox(width: AppSpacing.sm),
        ],
      ),
      body: const _GreetingBody(),
      bottomSheet: _Composer(
        controller: _composerController,
        hasInput: _hasInput,
      ),
    );
  }
}

class _GreetingBody extends StatelessWidget {
  const _GreetingBody();

  static const _suggestions = [
    (Icons.description_outlined, '帮我总结这个项目', '阅读工作区文件并生成结构化摘要'),
    (Icons.build_outlined, '修复一个 Bug', '描述问题,我会定位并给出补丁'),
    (Icons.auto_awesome_outlined, '写一个新功能', '从需求到实现,分步骤完成'),
    (Icons.travel_explore_outlined, '梳理代码结构', '生成仓库地图与依赖关系'),
  ];

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.xxl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '我能帮你做什么?',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              height: 1.25,
              color: semantic.textPrimary,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '由 Hermes 引擎驱动 · 支持多轮工具调用与人工审批',
            style: TextStyle(fontSize: 13.5, color: semantic.textTertiary),
          ),
          const SizedBox(height: AppSpacing.xl),
          ..._suggestions.map(
            (s) => Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: _SuggestionCard(
                icon: s.$1,
                title: s.$2,
                subtitle: s.$3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Material(
      color: semantic.card,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: () {},
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: semantic.border),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  color: AppColors.brandBlue.withValues(alpha: 0.12),
                ),
                child: Icon(icon, size: 20, color: AppColors.brandBlue),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: semantic.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: semantic.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.arrow_forward_ios_rounded,
                  size: 14, color: semantic.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({required this.controller, required this.hasInput});

  final TextEditingController controller;
  final bool hasInput;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.lg,
          AppSpacing.md,
        ),
        decoration: BoxDecoration(color: semantic.background),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: semantic.card,
            borderRadius: BorderRadius.circular(AppRadius.xl),
            border: Border.all(color: semantic.border),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.newline,
                  style: TextStyle(
                    fontSize: 15,
                    color: semantic.textPrimary,
                    height: 1.4,
                  ),
                  cursorColor: AppColors.brandBlue,
                  decoration: InputDecoration(
                    hintText: '给 Shelly 发送消息…',
                    hintStyle: TextStyle(
                      fontSize: 15,
                      color: semantic.textTertiary,
                    ),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              _SendButton(enabled: hasInput),
            ],
          ),
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return GradientButton(
      label: '',
      icon: Icons.arrow_upward_rounded,
      onPressed: enabled ? () {} : null,
    );
  }
}
