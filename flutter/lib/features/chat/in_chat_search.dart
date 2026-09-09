import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../state/chat_session.dart';

/// One search match: the transcript entry index it points at.
@immutable
class SearchMatch {
  const SearchMatch({required this.entryIndex});

  final int entryIndex;
}

/// Page-local in-conversation search state (PHASE 54): matches are the
/// transcript entry indexes whose user/assistant text contains [query],
/// case-insensitive. [next]/[previous] cycle the cursor; [copyWith] keeps
/// the widget stateless-friendly.
@immutable
class InChatSearchState {
  const InChatSearchState({
    this.query = '',
    this.matches = const [],
    this.currentIndex = 0,
  });

  final String query;
  final List<SearchMatch> matches;
  final int currentIndex;

  bool get isActive => query.trim().isNotEmpty;
  bool get hasMatches => matches.isNotEmpty;
  String get counterLabel => hasMatches
      ? '${currentIndex + 1}/${matches.length}'
      : (isActive ? '0/0' : '');

  SearchMatch? get currentMatch =>
      hasMatches && currentIndex < matches.length ? matches[currentIndex] : null;

  InChatSearchState copyWith({
    String? query,
    List<SearchMatch>? matches,
    int? currentIndex,
  }) {
    return InChatSearchState(
      query: query ?? this.query,
      matches: matches ?? this.matches,
      currentIndex: currentIndex ?? this.currentIndex,
    );
  }
}

/// Case-insensitive containment over user/assistant text content. Tool,
/// error and notice entries are skipped (they are machine-generated and
/// would flood matches).
List<SearchMatch> computeMatches(
    List<ChatEntry> entries, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return const [];
  final matches = <SearchMatch>[];
  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    final text = switch (entry) {
      UserEntry() => entry.text,
      AssistantEntry() => entry.text,
      _ => null,
    };
    if (text != null && text.toLowerCase().contains(needle)) {
      matches.add(SearchMatch(entryIndex: i));
    }
  }
  return matches;
}

/// Slim search bar toggled from the chat header: query field, prev/next,
/// n/m counter, close. All callbacks are supplied by the page.
class InChatSearchBar extends StatelessWidget {
  const InChatSearchBar({
    super.key,
    required this.state,
    required this.onQueryChanged,
    required this.onNext,
    required this.onPrevious,
    required this.onClose,
  });

  final InChatSearchState state;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: semantic.card,
        border: Border(
          bottom: BorderSide(color: semantic.border),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              autofocus: true,
              onChanged: onQueryChanged,
              style: const TextStyle(fontSize: 13.5),
              decoration: InputDecoration(
                hintText: '在当前会话中搜索…',
                isDense: true,
                prefixIcon: Icon(Icons.search_rounded,
                    size: 18, color: semantic.textTertiary),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md, vertical: AppSpacing.xs),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(state.counterLabel,
              style: TextStyle(
                  fontSize: 11.5,
                  color: state.hasMatches
                      ? semantic.textSecondary
                      : semantic.textTertiary)),
          IconButton(
            tooltip: '上一个',
            onPressed: state.hasMatches ? onPrevious : null,
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.keyboard_arrow_up_rounded,
                size: 20, color: semantic.textSecondary),
          ),
          IconButton(
            tooltip: '下一个',
            onPressed: state.hasMatches ? onNext : null,
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.keyboard_arrow_down_rounded,
                size: 20, color: semantic.textSecondary),
          ),
          IconButton(
            tooltip: '关闭搜索',
            onPressed: onClose,
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.close_rounded,
                size: 18, color: semantic.textTertiary),
          ),
        ],
      ),
    );
  }
}
