import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shelly_hermes/app.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('app shell renders chat tab and bottom navigation', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: ShellyApp()));
    await tester.pumpAndSettle();

    expect(find.text('你好,我是 Shelly'), findsOneWidget);
    expect(find.text('对话'), findsOneWidget);
    expect(find.text('任务'), findsOneWidget);
    expect(find.text('历史'), findsOneWidget);
    expect(find.text('能力'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
    expect(find.text('给 Shelly 发送消息…'), findsOneWidget);
  });

  testWidgets('bottom navigation switches to capabilities tab', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: ShellyApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('能力'));
    await tester.pumpAndSettle();

    expect(find.text('工作区工具'), findsOneWidget);
    expect(find.text('apply_patch'), findsOneWidget);
  });

  testWidgets('capabilities tab hosts the DSH plugin installer', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: ShellyApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('能力'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('插件(DSH)'),
      200,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('插件(DSH)'), findsOneWidget);
    expect(find.text('安装插件'), findsOneWidget);
  });

  testWidgets('profile tab shows agent profiles and provider presets',
      (tester) async {
    await tester.pumpWidget(const ProviderScope(child: ShellyApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();

    expect(find.text('Agent 档案'), findsOneWidget);
    expect(find.text('平衡助手'), findsOneWidget);
    expect(find.text('获取模型列表'), findsOneWidget);
    expect(find.text('DeepSeek'), findsOneWidget);
    expect(find.text('Ollama(本机)'), findsOneWidget);
  });

  testWidgets('profile tab switches agent profile on tap', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: ShellyApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('谨慎工程师'));
    await tester.pumpAndSettle();

    // The tapped profile renders its meta line.
    expect(find.textContaining('24 轮'), findsOneWidget);
  });
}
