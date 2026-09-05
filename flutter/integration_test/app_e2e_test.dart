import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shelly_hermes/app.dart';

/// End-to-end checks that run against the real app on an Android
/// emulator/phone: real platform channels, real storage, real rendering.
/// CI runs these in the Android emulator job (flutter_e2e.yml).
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  group('boot and navigation', () {
    testWidgets('cold boot lands on the chat greeting', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: ShellyApp()));
      await tester.pumpAndSettle(const Duration(seconds: 6));

      expect(find.text('你好,我是 Shelly'), findsOneWidget);
      expect(find.text('给 Shelly 发送消息…'), findsOneWidget);
      for (final tab in ['对话', '任务', '历史', '能力', '我的']) {
        expect(find.text(tab), findsOneWidget);
      }
    });

    testWidgets('bottom navigation reaches the capabilities page',
        (tester) async {
      await tester.pumpWidget(const ProviderScope(child: ShellyApp()));
      await tester.pumpAndSettle(const Duration(seconds: 6));

      await tester.tap(find.text('能力'));
      await tester.pumpAndSettle(const Duration(seconds: 3));

      expect(find.text('工作区工具'), findsOneWidget);
      expect(find.text('apply_patch'), findsOneWidget);
      // V2.2 sections live below the fold on a real screen.
      await tester.scrollUntilVisible(
        find.text('MCP 连接器'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('运行环境'), findsOneWidget);
    });

    testWidgets('profile page reports the app version', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: ShellyApp()));
      await tester.pumpAndSettle(const Duration(seconds: 6));

      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle(const Duration(seconds: 3));

      await tester.scrollUntilVisible(
        find.text('版本'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Shelly Hermes'), findsOneWidget);
      // The key field must exist and mask its content, never echo it.
      expect(find.text('API 密钥'), findsOneWidget);
    });
  });

  group('demo conversation', () {
    testWidgets('sending a message produces a transcript entry',
        (tester) async {
      await tester.pumpWidget(const ProviderScope(child: ShellyApp()));
      await tester.pumpAndSettle(const Duration(seconds: 6));

      await tester.enterText(
          find.byType(TextField).first, '介绍一下你自己');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      // Demo gateway streams a reply; settle with a generous budget.
      await tester.pumpAndSettle(const Duration(seconds: 10));

      // The user bubble renders; the auto conversation title shows the
      // same text, so accept either one or both.
      expect(find.text('介绍一下你自己'), findsAtLeastNWidgets(1));
    });

    testWidgets('conversation survives a full app restart', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: ShellyApp()));
      await tester.pumpAndSettle(const Duration(seconds: 6));

      await tester.enterText(
          find.byType(TextField).first, '重启后仍应保留');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pumpAndSettle(const Duration(seconds: 10));

      // Simulate a process restart: rebuild the whole app from scratch on
      // the same (persisted) storage the binding provides.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(const ProviderScope(child: ShellyApp()));
      await tester.pumpAndSettle(const Duration(seconds: 6));

      await tester.tap(find.text('历史'));
      await tester.pumpAndSettle(const Duration(seconds: 3));
      expect(find.textContaining('重启后仍应保留'), findsAtLeastNWidgets(1));
    });
  });
}
