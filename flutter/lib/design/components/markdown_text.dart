import 'package:flutter/material.dart';

import '../tokens.dart';
import 'code_block.dart';

/// Lightweight Markdown renderer tuned for chat transcripts: headings,
/// bullet/numbered lists, block quotes, fenced code blocks (syntax
/// highlighted via [CodeBlock]), inline code, bold/italic and links shown
/// as text. Deliberately dependency-free so styling stays under the design
/// system's control.
class MarkdownText extends StatelessWidget {
  const MarkdownText({super.key, required this.data});

  final String data;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final blocks = _parseBlocks(data);
    final children = <Widget>[];
    for (final block in blocks) {
      switch (block) {
        case _CodeFence(:final code, :final language):
          children.add(CodeBlock(code: code, language: language));
        case _Heading(:final level, :final text):
          children.add(Padding(
            padding: const EdgeInsets.only(top: AppSpacing.md, bottom: AppSpacing.xs),
            child: _styledText(
              text,
              semantic,
              fontSize: switch (level) {
                1 => 20.0,
                2 => 17.5,
                _ => 16.0,
              },
              weight: FontWeight.w700,
            ),
          ));
        case _Quote(:final text):
          children.add(Container(
            margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.md,
              AppSpacing.sm,
            ),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: AppColors.brandBlue.withValues(alpha: 0.6), width: 3),
              ),
              color: semantic.floating,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: _styledText(text, semantic,
                color: semantic.textSecondary, italic: true),
          ));
        case _ListItem(:final marker, :final text):
          children.add(Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 22,
                  child: _styledText(marker, semantic,
                      color: AppColors.brandBlue, weight: FontWeight.w600),
                ),
                Expanded(
                  child: _styledText(text, semantic),
                ),
              ],
            ),
          ));
        case _Paragraph(:final text):
          children.add(Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: _styledText(text, semantic),
          ));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Text _styledText(
    String raw,
    AppSemanticColors semantic, {
    double fontSize = 15,
    FontWeight weight = FontWeight.w400,
    Color? color,
    bool italic = false,
  }) {
    return Text.rich(
      _buildSpan(raw, semantic, fontSize, weight, color, italic),
      style: TextStyle(
        fontSize: fontSize,
        height: 1.55,
        color: color ?? semantic.textPrimary,
      ),
    );
  }

  InlineSpan _buildSpan(
    String raw,
    AppSemanticColors semantic,
    double fontSize,
    FontWeight weight,
    Color? color,
    bool italic,
  ) {
    final spans = <InlineSpan>[];
    final pattern = RegExp(r'(\*\*(.+?)\*\*)|(`(.+?)`)|(\*(.+?)\*)');
    var cursor = 0;
    for (final match in pattern.allMatches(raw)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: raw.substring(cursor, match.start)));
      }
      if (match.group(2) != null) {
        spans.add(TextSpan(
          text: match.group(2),
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: color ?? semantic.textPrimary,
            fontStyle: italic ? FontStyle.italic : FontStyle.normal,
          ),
        ));
      } else if (match.group(4) != null) {
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 2),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: semantic.floating,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: semantic.border),
            ),
            child: Text(
              match.group(4)!,
              style: TextStyle(
                fontSize: fontSize - 2,
                fontFamily: 'monospace',
                color: AppColors.brandViolet,
              ),
            ),
          ),
        ));
      } else if (match.group(6) != null) {
        spans.add(TextSpan(
          text: match.group(6),
          style: TextStyle(
            fontStyle: FontStyle.italic,
            color: color ?? semantic.textPrimary,
            fontWeight: weight,
          ),
        ));
      }
      cursor = match.end;
    }
    if (cursor < raw.length) {
      spans.add(TextSpan(text: raw.substring(cursor)));
    }
    return TextSpan(
      style: TextStyle(
        fontWeight: weight,
        fontStyle: italic ? FontStyle.italic : FontStyle.normal,
      ),
      children: spans,
    );
  }
}

sealed class _Block {}

class _Paragraph extends _Block {
  _Paragraph(this.text);
  final String text;
}

class _Heading extends _Block {
  _Heading(this.level, this.text);
  final int level;
  final String text;
}

class _Quote extends _Block {
  _Quote(this.text);
  final String text;
}

class _ListItem extends _Block {
  _ListItem(this.marker, this.text);
  final String marker;
  final String text;
}

class _CodeFence extends _Block {
  _CodeFence(this.code, this.language);
  final String code;
  final String? language;
}

List<_Block> _parseBlocks(String data) {
  final blocks = <_Block>[];
  final lines = data.split('\n');
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    if (line.trimLeft().startsWith('```')) {
      final language = line.trim().substring(3).trim();
      final code = <String>[];
      i += 1;
      while (i < lines.length && !lines[i].trimLeft().startsWith('```')) {
        code.add(lines[i]);
        i += 1;
      }
      i += 1; // closing fence
      blocks.add(_CodeFence(code.join('\n'), language.isEmpty ? null : language));
      continue;
    }
    final trimmed = line.trimLeft();
    final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(trimmed);
    if (heading != null) {
      blocks.add(_Heading(heading.group(1)!.length, heading.group(2)!));
      i += 1;
      continue;
    }
    if (trimmed.startsWith('> ')) {
      final quote = <String>[trimmed.substring(2)];
      i += 1;
      while (i < lines.length && lines[i].trimLeft().startsWith('> ')) {
        quote.add(lines[i].trimLeft().substring(2));
        i += 1;
      }
      blocks.add(_Quote(quote.join('\n')));
      continue;
    }
    final bullet = RegExp(r'^[-*]\s+(.*)$').firstMatch(trimmed);
    if (bullet != null) {
      blocks.add(_ListItem('•', bullet.group(1)!));
      i += 1;
      continue;
    }
    final numbered = RegExp(r'^(\d+)[.、]\s+(.*)$').firstMatch(trimmed);
    if (numbered != null) {
      blocks.add(_ListItem('${numbered.group(1)}.', numbered.group(2)!));
      i += 1;
      continue;
    }
    if (trimmed.isEmpty) {
      i += 1;
      continue;
    }
    // Paragraph: consume until blank line or another block starter.
    final paragraph = <String>[line];
    i += 1;
    while (i < lines.length) {
      final next = lines[i];
      final nextTrimmed = next.trimLeft();
      if (nextTrimmed.isEmpty ||
          nextTrimmed.startsWith('```') ||
          nextTrimmed.startsWith('#') ||
          nextTrimmed.startsWith('> ') ||
          RegExp(r'^[-*]\s+').hasMatch(nextTrimmed) ||
          RegExp(r'^\d+[.、]\s+').hasMatch(nextTrimmed)) {
        break;
      }
      paragraph.add(next);
      i += 1;
    }
    blocks.add(_Paragraph(paragraph.join('\n')));
  }
  return blocks;
}
