import 'package:flutter/material.dart';

import '../../design/components/empty_state.dart';
import '../../design/tokens.dart';

/// Task queue. Stage 1 ships the frame; multi-task execution with per-task
/// cancel lands in stage 4 on top of the Dart task queue.
class TasksPage extends StatelessWidget {
  const TasksPage({super.key});

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: AppSpacing.lg,
        title: Text(
          '任务',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w700,
            color: semantic.textPrimary,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '新建任务',
            onPressed: () {},
            icon: const Icon(Icons.add_circle_outline_rounded, size: 24),
          ),
          const SizedBox(width: AppSpacing.sm),
        ],
      ),
      body: const EmptyState(
        icon: Icons.account_tree_outlined,
        title: '暂无进行中的任务',
        body: '在对话中发起多步骤工作后,任务会出现在这里,支持并行执行与单独取消。',
      ),
    );
  }
}
