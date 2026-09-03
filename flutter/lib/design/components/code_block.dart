import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:highlight/highlight.dart' as hl;

import '../tokens.dart';

/// Syntax-highlighted code block with a floating language tag and one-tap
/// copy. Adapts to both themes by tinting a small hand-picked token palette
/// over the card surface instead of shipping a fixed dark-only theme.
class CodeBlock extends StatelessWidget {
  const CodeBlock({super.key, required this.code, this.language});

  final String code;
  final String? language;

  static const _palette = (
    keyword: Color(0xFFC792EA),
    string: Color(0xFFA5D6A7),
    number: Color(0xFFF78C6C),
    comment: Color(0xFF7A7A85),
    builtin: Color(0xFF82AAFF),
  );

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final highlighted = language == null
        ? null
        : hl.highlight.parse(code, language: language);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        color: const Color(0xFF101013),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: semantic.border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm + 2,
                AppSpacing.sm + 2,
                AppSpacing.sm + 2,
              ),
              child: Row(
                children: [
                  Text(
                    (language ?? 'text').toUpperCase(),
                    style: const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                      color: Color(0xFF8A8A95),
                    ),
                  ),
                  const Spacer(),
                  _CopyButton(code: code),
                ],
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.lg,
              ),
              child: _HighlightedCode(
                code: code,
                highlighted: highlighted,
                palette: _palette,
                defaultColor: const Color(0xFFE4E4EA),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.code});

  final String code;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: _copy,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _copied ? Icons.check : Icons.copy_outlined,
              size: 14,
              color: _copied ? AppColors.success : const Color(0xFF8A8A95),
            ),
            const SizedBox(width: 4),
            Text(
              _copied ? '已复制' : '复制',
              style: TextStyle(
                fontSize: 12,
                color: _copied ? AppColors.success : const Color(0xFF8A8A95),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HighlightedCode extends StatelessWidget {
  const _HighlightedCode({
    required this.code,
    required this.highlighted,
    required this.palette,
    required this.defaultColor,
  });

  final String code;
  final hl.Result? highlighted;
  final ({Color keyword, Color string, Color number, Color comment, Color builtin}) palette;
  final Color defaultColor;

  static const String _monoFamily = 'JetBrains Mono, Menlo, Consolas, monospace';

  Color _colorFor(String? cls) {
    if (cls == null) return defaultColor;
    if (cls.startsWith('language-')) return palette.builtin;
    return switch (cls) {
      'keyword' ||
      'tag' ||
      'selector-tag' ||
      'literal' ||
      'section' ||
      'name' => palette.keyword,
      'string' || 'regexp' || 'addition' => palette.string,
      'number' || 'attr' || 'attribute' || 'variable' => palette.number,
      'comment' || 'quote' || 'deletion' || 'meta' => palette.comment,
      'built_in' || 'type' || 'title' || 'title.class_' || 'function_' => palette.builtin,
      _ => defaultColor,
    };
  }

  @override
  Widget build(BuildContext context) {
    final spans = <TextSpan>[];
    final nodes = highlighted?.nodes ?? [hl.Node(value: code)];
    for (final node in nodes) {
      spans.add(TextSpan(
        text: node.value,
        style: TextStyle(color: _colorFor(node.className)),
      ));
    }
    return Text.rich(
      TextSpan(style: const TextStyle(fontFamily: _monoFamily, fontSize: 13, height: 1.6), children: spans),
    );
  }
}
