import 'package:flutter/material.dart';

import '../tokens.dart';

/// Shimmering placeholder used while conversations, tasks and histories load.
/// Draws rounded blocks that sweep a soft highlight left→right.
class SkeletonBlock extends StatefulWidget {
  const SkeletonBlock({
    super.key,
    this.width,
    required this.height,
    this.radius = AppRadius.md,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  State<SkeletonBlock> createState() => _SkeletonBlockState();
}

class _SkeletonBlockState extends State<SkeletonBlock>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            gradient: LinearGradient(
              begin: Alignment(-1 - 2 + 4 * _controller.value, 0),
              end: Alignment(0 + 2 * _controller.value, 0),
              colors: [
                semantic.floating,
                semantic.border.withValues(alpha: 0.6),
                semantic.floating,
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A full skeleton for a chat message: avatar dot + two text lines.
class SkeletonMessageRow extends StatelessWidget {
  const SkeletonMessageRow({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonBlock(width: 28, height: 28, radius: 14),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonBlock(
                  width: double.infinity,
                  height: 12,
                  radius: AppRadius.sm,
                ),
                const SizedBox(height: AppSpacing.sm),
                FractionallySizedBox(
                  widthFactor: 0.6,
                  child: SkeletonBlock(
                    height: 12,
                    radius: AppRadius.sm,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
