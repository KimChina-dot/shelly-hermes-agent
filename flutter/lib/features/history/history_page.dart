import 'package:flutter/material.dart';

import '../../design/components/empty_state.dart';
import '../../design/tokens.dart';

/// Session history with resume / fork entry points (data wiring in stage 4).
class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: AppSpacing.lg,
        title: Text(
          '历史',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w700,
            color: semantic.textPrimary,
          ),
        ),
      ),
      body: const EmptyState(
        icon: Icons.history_rounded,
        title: '暂无历史会话',
        body: '每次对话完成后自动存档,可随时恢复上下文或从某个检查点分叉重跑。',
      ),
    );
  }
}
