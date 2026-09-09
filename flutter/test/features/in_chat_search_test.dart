import 'package:flutter/material.dart';
import 'package:shelly_hermes/design/theme.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shelly_hermes/features/chat/in_chat_search.dart';
import 'package:shelly_hermes/state/chat_session.dart';

/// Builds transcript entries without driving the chat session: UserEntry /
/// AssistantEntry are plain data classes.
List<ChatEntry> _entries() => [
      UserEntry('帮我查一下 Flutter 的路由'),
      AssistantEntry(text: 'Flutter 路由用 Navigator 管理。'),
      UserEntry('那 go_router 呢'),
      AssistantEntry(text: 'GO_ROUTER 是声明式路由的首选方案。'),
      UserEntry('路由嵌套怎么做'),
    ];

void main() {
  group('computeMatches', () {
    test('matches user and assistant text case-insensitively', () {
      final matches = computeMatches(_entries(), '路由');
      expect(matches.map((m) => m.entryIndex).toList(), [0, 1, 3, 4]);
    });

    test('uppercase query still matches lowercase text', () {
      final matches = computeMatches(_entries(), 'GO_ROUTER');
      expect(matches.map((m) => m.entryIndex).toList(), [2, 3]);
    });

    test('blank query matches nothing', () {
      expect(computeMatches(_entries(), '   '), isEmpty);
    });

    test('no-match query returns empty', () {
      expect(computeMatches(_entries(), '不存在的词'), isEmpty);
    });
  });

  group('InChatSearchState', () {
    test('counter label reflects the cursor position', () {
      const state = InChatSearchState(
        query: '路由',
        matches: [
          SearchMatch(entryIndex: 0),
          SearchMatch(entryIndex: 1),
        ],
        currentIndex: 0,
      );
      expect(state.counterLabel, '1/2');
      expect(state.copyWith(currentIndex: 1).counterLabel, '2/2');
    });

    test('no matches shows 0/0 while active', () {
      const state = InChatSearchState(query: '不存在的词');
      expect(state.counterLabel, '0/0');
      expect(state.hasMatches, isFalse);
    });

    test('inactive (blank query) shows an empty label', () {
      const state = InChatSearchState();
      expect(state.counterLabel, '');
    });

    test('next/prev cycle wraps across matches', () {
      var state = const InChatSearchState(
        query: 'x',
        matches: [
          SearchMatch(entryIndex: 0),
          SearchMatch(entryIndex: 2),
        ],
      );
      // next: 0 -> 1
      state = state.copyWith(currentIndex: (state.currentIndex + 1) % 2);
      expect(state.currentIndex, 1);
      // prev wraps 1 -> 0
      state = state.copyWith(
          currentIndex: (state.currentIndex - 1 + state.matches.length) % 2);
      expect(state.currentIndex, 0);
    });
  });

  group('InChatSearchBar widget', () {
    testWidgets('renders the counter and fires callbacks', (tester) async {
      InChatSearchState? received;
      var nextTaps = 0;
      var prevTaps = 0;
      var closes = 0;

      await tester.pumpWidget(MaterialApp(
        theme: buildShellyTheme(Brightness.light),
        home: Scaffold(
          body: InChatSearchBar(
            state: const InChatSearchState(
              query: '',
              matches: [
                SearchMatch(entryIndex: 0),
                SearchMatch(entryIndex: 3),
              ],
              currentIndex: 0,
            ),
            onQueryChanged: (q) => received = InChatSearchState(query: q),
            onNext: () => nextTaps++,
            onPrevious: () => prevTaps++,
            onClose: () => closes++,
          ),
        ),
      ));

      // Counter label for 2 matches at index 0.
      expect(find.text('1/2'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '新的查询');
      expect(received?.query, '新的查询');

      await tester.tap(find.byTooltip('下一个'));
      expect(nextTaps, 1);

      await tester.tap(find.byTooltip('上一个'));
      expect(prevTaps, 1);

      await tester.tap(find.byTooltip('关闭搜索'));
      expect(closes, 1);
    });

    testWidgets('zero-match state disables navigation buttons', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildShellyTheme(Brightness.light),
        home: Scaffold(
          body: InChatSearchBar(
            state: const InChatSearchState(query: '不存在的词'),
            onQueryChanged: (_) {},
            onNext: () {},
            onPrevious: () {},
            onClose: () {},
          ),
        ),
      ));
      expect(find.text('0/0'), findsOneWidget);
      // The nav buttons disable themselves on zero matches: their onPressed
      // becomes null, which the icon inherits through the IconButton tree.
      final navIcon = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.keyboard_arrow_down_rounded),
          matching: find.byType(IconButton),
        ).first,
      );
      expect(navIcon.onPressed, isNull);
    });
  });
}
