import 'package:flutter/material.dart';

import '../../design/components/gradient_avatar.dart';
import '../../design/tokens.dart';

/// Profile & settings. Stage 1 renders the frame with placeholder values;
/// stage 4 wires model config (masked keys), workspace picker and theme mode.
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: AppSpacing.lg,
        title: Text(
          '我的',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w700,
            color: semantic.textPrimary,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.sm,
          AppSpacing.lg,
          AppSpacing.xxl,
        ),
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color: semantic.card,
              borderRadius: BorderRadius.circular(AppRadius.xl),
              border: Border.all(color: semantic.border),
            ),
            child: Row(
              children: [
                const GradientAvatar(size: AvatarSize.large, glow: true),
                const SizedBox(width: AppSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Shelly Hermes',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: semantic.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '版本 1.0.0 · 引擎 Hermes Core (Dart)',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: semantic.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          _SectionTitle(text: '模型配置', semantic: semantic),
          const SizedBox(height: AppSpacing.md),
          _SettingsCard(children: [
            _SettingsRow(
              icon: Icons.key_outlined,
              title: 'API 密钥',
              value: '未配置',
              semantic: semantic,
            ),
            _Divider(semantic: semantic),
            _SettingsRow(
              icon: Icons.hub_outlined,
              title: '接口地址',
              value: '默认网关',
              semantic: semantic,
            ),
            _Divider(semantic: semantic),
            _SettingsRow(
              icon: Icons.smart_toy_outlined,
              title: '默认模型',
              value: '未选择',
              semantic: semantic,
            ),
          ]),
          const SizedBox(height: AppSpacing.xl),
          _SectionTitle(text: '通用', semantic: semantic),
          const SizedBox(height: AppSpacing.md),
          _SettingsCard(children: [
            _SettingsRow(
              icon: Icons.folder_open_rounded,
              title: '工作区',
              value: '未选择',
              semantic: semantic,
            ),
            _Divider(semantic: semantic),
            _SettingsRow(
              icon: Icons.dark_mode_outlined,
              title: '外观',
              value: '跟随系统',
              semantic: semantic,
            ),
          ]),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.text, required this.semantic});

  final String text;
  final AppSemanticColors semantic;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
        color: semantic.textTertiary,
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Container(
      decoration: BoxDecoration(
        color: semantic.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: semantic.border),
      ),
      child: Column(children: children),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.semantic,
  });

  final IconData icon;
  final String title;
  final String value;
  final AppSemanticColors semantic;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {},
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.lg,
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: semantic.textSecondary),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 15,
                  color: semantic.textPrimary,
                ),
              ),
            ),
            Text(
              value,
              style: TextStyle(fontSize: 13.5, color: semantic.textTertiary),
            ),
            const SizedBox(width: AppSpacing.xs + 2),
            Icon(Icons.chevron_right_rounded,
                size: 18, color: semantic.textTertiary),
          ],
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider({required this.semantic});

  final AppSemanticColors semantic;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 20 + AppSpacing.lg),
      child: Divider(color: semantic.border, height: 1),
    );
  }
}
