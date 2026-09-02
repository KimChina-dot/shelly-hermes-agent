import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart' show ApprovalDecision;
import '../../core/approval_broker.dart' show PendingApproval;
import '../../design/components/buttons.dart';
import '../../design/components/risk_chip.dart';
import '../../design/tokens.dart';
import '../../state/chat_session.dart';

/// High-visual-weight approval modal. Each pending request — a whole tool
/// call, or a single apply_patch hunk the engine sends sequentially — gets
/// its own decision card with risk coloring, rendered diff, and
/// 允许/拒绝 actions. Rejects may carry a reason delivered back to the model.
class ApprovalSheet extends ConsumerStatefulWidget {
  const ApprovalSheet({super.key});

  @override
  ConsumerState<ApprovalSheet> createState() => _ApprovalSheetState();
}

class _ApprovalSheetState extends ConsumerState<ApprovalSheet> {
  final _reasonController = TextEditingController();
  bool _showReasonField = false;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  void _decide(PendingApproval approval, bool approve) {
    ref
        .read(chatSessionProvider.notifier)
        .resolveApproval(approval, approve ? ApprovalDecision.approve : ApprovalDecision.reject);
    if (!approve) {
      setState(() => _showReasonField = false);
      _reasonController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final queue = ref.watch(approvalQueueProvider);
    final session = ref.watch(chatSessionProvider);

    if (queue.isEmpty || session.phase != SessionPhase.waitingApproval) {
      return const SizedBox.shrink();
    }
    final approval = queue.first;
    final call = approval.call;
    final args = _decodeArgs(call.argumentsJson);
    final hunkIndex = (args['hunk_index'] as num?)?.toInt() ?? 0;
    final hunkCount = (args['hunk_count'] as num?)?.toInt() ?? 0;
    final isHunk = call.name == 'apply_patch_hunk';
    final path = args['path'] as String?;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: semantic.floating,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
          border: Border(top: BorderSide(color: AppColors.warning.withValues(alpha: 0.5), width: 2)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl, AppSpacing.lg, AppSpacing.xl, AppSpacing.sm,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: [
                          AppColors.warning.withValues(alpha: 0.25),
                          AppColors.danger.withValues(alpha: 0.25),
                        ]),
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      child: const Icon(Icons.verified_user_outlined,
                          size: 19, color: AppColors.warning),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('需要你的批准',
                              style: TextStyle(
                                  fontSize: 16.5, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 2),
                          Text(
                            isHunk
                                ? '补丁共 $hunkCount 段,当前第 $hunkIndex 段'
                                : '工具 "${call.name}" 请求执行',
                            style: TextStyle(
                                fontSize: 12.5, color: semantic.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (queue.length > 1)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
                  child: Text('还有 ${queue.length - 1} 个请求排队中',
                      style: TextStyle(
                          fontSize: 11.5, color: semantic.textTertiary)),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
                child: _DecisionCard(
                  approval: approval,
                  onApprove: () => _decide(approval, true),
                  onReject: () => _decide(approval, false),
                  reasonController: _reasonController,
                  showReasonField: _showReasonField,
                  onToggleReason: () =>
                      setState(() => _showReasonField = !_showReasonField),
                ),
              ),
              if (path != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.xl, AppSpacing.sm, AppSpacing.xl, 0,
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.insert_drive_file_outlined,
                          size: 13, color: semantic.textTertiary),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(path,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 11.5,
                                fontFamily: 'monospace',
                                color: semantic.textTertiary)),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Row(
                  children: [
                    Expanded(
                      child: SecondaryButton(
                        label: '拒绝',
                        danger: true,
                        onPressed: () => _decide(approval, false),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      flex: 2,
                      child: GradientButton(
                        label: '允许执行',
                        onPressed: () => _decide(approval, true),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DecisionCard extends StatelessWidget {
  const _DecisionCard({
    required this.approval,
    required this.onApprove,
    required this.onReject,
    required this.reasonController,
    required this.showReasonField,
    required this.onToggleReason,
  });

  final PendingApproval approval;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final TextEditingController reasonController;
  final bool showReasonField;
  final VoidCallback onToggleReason;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final call = approval.call;
    final args = _decodeArgs(call.argumentsJson);
    final hunk = args['hunk'] as String?;

    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: semantic.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: semantic.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  call.name == 'apply_patch_hunk' ? '补丁片段' : _toolTitle(call.name),
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
              RiskChip(level: _riskOf(call.name)),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          if (hunk != null)
            _DiffView(patch: hunk)
          else if (call.name == 'write_file')
            _DiffView(
              patch:
                  '@@ 新文件 @@\n${(args['content'] as String?) ?? ''}'.split('\n').map((l) => l.isEmpty ? l : '+$l').join('\n'),
            )
          else
            Text(
              const JsonEncoder.withIndent('  ').convert(args),
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                height: 1.5,
                color: semantic.textSecondary,
              ),
            ),
          if (!showReasonField)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onToggleReason,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                child: Text('附加拒绝理由',
                    style: TextStyle(
                        fontSize: 11.5, color: semantic.textTertiary)),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: TextField(
                controller: reasonController,
                maxLines: 2,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: '告诉模型为什么拒绝(可选)',
                  hintStyle: TextStyle(
                      fontSize: 12, color: semantic.textTertiary),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DiffView extends StatelessWidget {
  const _DiffView({required this.patch});

  final String patch;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final lines = patch.split('\n');
    return Container(
      decoration: BoxDecoration(
        color: semantic.background,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: semantic.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final line in lines.take(40))
            Container(
              width: double.infinity,
              color: line.startsWith('+')
                  ? AppColors.success.withValues(alpha: 0.10)
                  : line.startsWith('-')
                      ? AppColors.danger.withValues(alpha: 0.10)
                      : Colors.transparent,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 2),
              child: Text(
                line.isEmpty ? ' ' : line,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.45,
                  fontFamily: 'monospace',
                  color: line.startsWith('+')
                      ? AppColors.success
                      : line.startsWith('-')
                          ? AppColors.danger
                          : semantic.textSecondary,
                ),
              ),
            ),
          if (lines.length > 40)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Text('… 共 ${lines.length} 行',
                  style: TextStyle(fontSize: 11, color: semantic.textTertiary)),
            ),
        ],
      ),
    );
  }
}

Map<String, dynamic> _decodeArgs(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
  } catch (_) {}
  return const {};
}

String _toolTitle(String name) => switch (name) {
      'write_file' => '写入文件',
      'apply_patch' => '应用补丁',
      _ => name,
    };

RiskLevel _riskOf(String name) => switch (name) {
      'apply_patch' || 'apply_patch_hunk' => RiskLevel.medium,
      'write_file' => RiskLevel.medium,
      'run_command' || 'delete_file' => RiskLevel.high,
      _ => RiskLevel.low,
    };
