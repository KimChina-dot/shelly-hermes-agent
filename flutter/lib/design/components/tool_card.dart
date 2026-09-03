import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../state/chat_session.dart';
import '../tokens.dart';

/// Inline tool execution card shown in the chat transcript: status pill,
/// expandable argument/result detail, and a pulsing indicator while running.
class ToolCard extends StatefulWidget {
  const ToolCard({super.key, required this.entry, this.isPlugin = false});

  final ToolEntry entry;

  /// True when the tool comes from a DSH plugin rather than the core
  /// workspace set; renders a small 插件 badge next to the title.
  final bool isPlugin;

  @override
  State<ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<ToolCard>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: AppMotion.normal,
    lowerBound: 0.35,
    upperBound: 1.0,
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final running = widget.entry.status == ToolRunStatus.running;
    if (!running) {
      // Stop the animation once the outcome is known.
      _pulse.stop();
    }
    final failed = widget.entry.status == ToolRunStatus.failed;

    final accent = failed
        ? AppColors.danger
        : running
            ? AppColors.brandBlue
            : AppColors.success;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        childrenPadding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          0,
          AppSpacing.md,
          AppSpacing.md,
        ),
        backgroundColor: semantic.card,
        collapsedBackgroundColor: semantic.card,
        iconColor: semantic.textTertiary,
        collapsedIconColor: semantic.textTertiary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: BorderSide(
            color: accent.withValues(alpha: failed || running ? 0.4 : 0.25),
          ),
        ),
        collapsedShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: BorderSide(
            color: accent.withValues(alpha: failed || running ? 0.4 : 0.25),
          ),
        ),
        initiallyExpanded: false,
        onExpansionChanged: (v) => setState(() => _expanded = v),
          leading: _ToolIcon(name: widget.entry.call.name, accent: accent),
          title: Row(
            children: [
              Flexible(
                child: Text(
                  _toolTitle(widget.entry.call.name),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: semantic.textPrimary,
                  ),
                ),
              ),
              if (widget.isPlugin) ...[
                const SizedBox(width: AppSpacing.sm),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.brandViolet.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text('插件',
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: AppColors.brandViolet)),
                ),
              ],
              const SizedBox(width: AppSpacing.sm),
              _StatusPill(
                status: widget.entry.status,
                accent: accent,
                pulse: _pulse,
              ),
            ],
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              widget.entry.status == ToolRunStatus.running
                  ? '正在执行…'
                  : '${widget.entry.durationMillis}ms · ${_briefTarget()}',
              style: TextStyle(fontSize: 12, color: semantic.textTertiary),
            ),
          ),
          trailing: Icon(
            _expanded ? Icons.expand_less : Icons.expand_more,
            size: 18,
            color: semantic.textTertiary,
          ),
          children: [
            _DetailSection(
              label: '参数',
              body: _prettyJson(widget.entry.call.argumentsJson),
              semantic: semantic,
            ),
            if (widget.entry.result != null)
              _DetailSection(
                label: failed ? '错误' : '结果',
                body: widget.entry.result!,
                semantic: semantic,
                isError: failed,
              ),
          ],
        ),
      );
  }

  String _briefTarget() {
    final args = widget.entry.call.argumentsJson;
    final path = _tryString(args, 'path');
    if (path != null) return path;
    final query = _tryString(args, 'query');
    if (query != null) return '"$query"';
    return _toolTitle(widget.entry.call.name);
  }

  String? _tryString(String json, String key) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map && decoded[key] is String) return decoded[key] as String;
    } catch (_) {}
    return null;
  }
}

String _prettyJson(String raw) {
  try {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(jsonDecode(raw));
  } catch (_) {
    return raw;
  }
}

String _toolTitle(String name) => switch (name) {
      'read_file' => '读取文件',
      'write_file' => '写入文件',
      'apply_patch' => '应用补丁',
      'apply_patch_hunk' => '补丁片段',
      'list_files' => '列出文件',
      'search_files' => '搜索文件',
      'exists' => '检查存在',
      _ => name,
    };

class _ToolIcon extends StatelessWidget {
  const _ToolIcon({required this.name, required this.accent});

  final String name;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Icon(_iconFor(name), size: 17, color: accent),
    );
  }

  IconData _iconFor(String name) => switch (name) {
        'read_file' => Icons.article_outlined,
        'write_file' => Icons.edit_note_outlined,
        'apply_patch' || 'apply_patch_hunk' => Icons.difference_outlined,
        'list_files' => Icons.folder_open_outlined,
        'search_files' => Icons.search,
        _ => Icons.build_outlined,
      };
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.status,
    required this.accent,
    required this.pulse,
  });

  final ToolRunStatus status;
  final Color accent;
  final Animation<double> pulse;

  @override
  Widget build(BuildContext context) {
    final (label, icon) = switch (status) {
      ToolRunStatus.running => ('执行中', Icons.sync),
      ToolRunStatus.succeeded => ('完成', Icons.check),
      ToolRunStatus.failed => ('失败', Icons.close),
    };
    final color = status == ToolRunStatus.running && pulse.isAnimating
        ? Color.lerp(accent, Colors.transparent, pulse.value)!
        : accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailSection extends StatelessWidget {
  const _DetailSection({
    required this.label,
    required this.body,
    required this.semantic,
    this.isError = false,
  });

  final String label;
  final String body;
  final AppSemanticColors semantic;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final maxLines = math.max(1, '\n'.allMatches(body).length + 1);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
              color: semantic.textTertiary,
            ),
          ),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              color: semantic.background,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: semantic.border),
            ),
            child: Text(
              body,
              maxLines: maxLines,
              overflow: TextOverflow.fade,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                fontFamily: 'monospace',
                color: isError ? AppColors.danger : semantic.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
