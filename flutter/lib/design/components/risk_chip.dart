import 'package:flutter/material.dart';

import '../tokens.dart';

enum RiskLevel { low, medium, high }

/// Colored risk chip used on approval screens and tool cards. Each level
/// carries a 12% tinted fill, a 35% border of the same hue, and an icon so
/// severity is readable without color alone.
class RiskChip extends StatelessWidget {
  const RiskChip({super.key, required this.level, this.label});

  final RiskLevel level;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final (color, icon, defaultLabel) = switch (level) {
      RiskLevel.low => (AppColors.success, Icons.shield_outlined, '低风险'),
      RiskLevel.medium => (AppColors.warning, Icons.error_outline, '中风险'),
      RiskLevel.high => (AppColors.danger, Icons.warning_amber_outlined, '高风险'),
    };
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs + 2,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: AppSpacing.xs + 2),
          Text(
            label ?? defaultLabel,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: semantic.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
