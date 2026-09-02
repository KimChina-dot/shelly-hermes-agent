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
}
