import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shelly_hermes/core/memory/consolidation.dart' hide MemoryTier;
import 'package:shelly_hermes/core/memory/memory_store.dart';
import 'package:shelly_hermes/design/theme.dart';
import 'package:shelly_hermes/features/memory/memory_page.dart';
import 'package:shelly_hermes/features/memory/memory_settings_page.dart';
import 'package:shelly_hermes/state/chat_session.dart';

/// PHASE 47: tiered memory UI — three-section grouping with per-tier
/// counts, the per-fact promote control cycling tiers through the store,
/// the 整理记忆 consolidation entry surfacing the report, and the tier
/// settings persisting as plain int prefs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  Future<void> pumpMemoryPage(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildShellyTheme(Brightness.light),
          home: const MemoryPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Finds the promote (调整层级) button on the fact card that renders
  /// [text]: the upgrade icon inside the card containing that text.
  Finder promoteButtonFor(String text) => find.descendant(
        of: find.ancestor(
          of: find.text(text),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Container &&
                widget.decoration is BoxDecoration,
          ),
        ),
        matching: find.byIcon(Icons.upgrade_rounded),
      );

  group('memory tier page', () {
    testWidgets('renders three tier sections with per-tier counts', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      container = ProviderContainer(overrides: [
        memoryStoreProvider.overrideWith((ref) async =>
            MemoryStore(await SharedPreferences.getInstance())),
      ]);
      addTearDown(container.dispose);
      final store = await container.read(memoryStoreProvider.future);
      await store!.addFacts(['用户偏好简洁的中文回复'], at: DateTime(2026, 9, 1));

      await pumpMemoryPage(tester);

      // Section headers carry the per-tier counts: the fresh fact lands in
      // 回忆 · 1, the other two tiers show their empty hints.
      expect(find.text('回忆 · 1'), findsOneWidget);
      expect(find.text('核心 · 0'), findsOneWidget);
      expect(find.text('归档 · 0'), findsOneWidget);
      expect(find.textContaining('核心层还没有记忆'), findsOneWidget);
      expect(find.textContaining('归档层暂时是空的'), findsOneWidget);
      expect(find.text('用户偏好简洁的中文回复'), findsOneWidget);
      expect(find.textContaining('自动记忆'), findsOneWidget);
    });

    testWidgets('promote control cycles the tier through the store', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      container = ProviderContainer(overrides: [
        memoryStoreProvider.overrideWith((ref) async =>
            MemoryStore(await SharedPreferences.getInstance())),
      ]);
      addTearDown(container.dispose);
      final store = await container.read(memoryStoreProvider.future);
      await store!.addFacts(['用户在北京工作'], at: DateTime(2026, 9, 1));

      await pumpMemoryPage(tester);
      expect(find.text('回忆 · 1'), findsOneWidget);

      // 回忆 → 核心: the row's promote control upgrades the fact and the
      // invalidated provider re-renders the counts.
      await tester.ensureVisible(promoteButtonFor('用户在北京工作'));
      await tester.pumpAndSettle();
      await tester.tap(promoteButtonFor('用户在北京工作'));
      await tester.pumpAndSettle();
      expect(store.loadByTier(MemoryTier.core), hasLength(1));
      expect(store.loadFacts().single.tier, MemoryTier.core);
      expect(find.text('核心 · 1'), findsOneWidget);
      expect(find.text('回忆 · 0'), findsOneWidget);

      // 核心 → 归档: the cycle wraps around past the top.
      await tester.ensureVisible(promoteButtonFor('用户在北京工作'));
      await tester.pumpAndSettle();
      await tester.tap(promoteButtonFor('用户在北京工作'));
      await tester.pumpAndSettle();
      expect(store.loadByTier(MemoryTier.core), isEmpty);
      expect(store.loadByTier(MemoryTier.archival), hasLength(1));
      expect(store.loadFacts().single.tier, MemoryTier.archival);
      expect(find.text('归档 · 1'), findsOneWidget);
    });

    testWidgets('整理记忆 runs the consolidator and reports the counts', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      container = ProviderContainer(overrides: [
        memoryStoreProvider.overrideWith((ref) async =>
            MemoryStore(await SharedPreferences.getInstance())),
      ]);
      addTearDown(container.dispose);
      final store = await container.read(memoryStoreProvider.future);
      await store!.addFacts(['用户偏好简洁的中文回复'], at: DateTime(2026, 9, 1));

      await pumpMemoryPage(tester);

      await tester.tap(find.text('整理记忆'));
      await tester.pumpAndSettle();

      // The deterministic pass (no summarizer) leaves an empty ledger
      // untouched and reports all four counters as zero.
      final report = await MemoryConsolidator().consolidate(store);
      expect(report.merged, 0);
      expect(report.demoted, 0);
      expect(report.evicted, 0);
      expect(report.synthesized, 0);
      expect(store.loadFacts(), hasLength(1));

      // The report surfaces the four counters from the consolidation pass.
      expect(
        find.textContaining('整理完成:合并'),
        findsOneWidget,
      );
      final snackText = tester
          .widget<SnackBar>(find.byType(SnackBar))
          .content;
      expect(snackText, isA<Text>());
      expect(
        (snackText as Text).data,
        contains('合成 0'),
      );
    });

    testWidgets('shows the tier sections empty-state for a fresh store', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      container = ProviderContainer(overrides: [
        memoryStoreProvider.overrideWith((ref) async =>
            MemoryStore(await SharedPreferences.getInstance())),
      ]);
      addTearDown(container.dispose);

      await pumpMemoryPage(tester);

      expect(find.text('核心 · 0'), findsOneWidget);
      expect(find.text('回忆 · 0'), findsOneWidget);
      expect(find.text('归档 · 0'), findsOneWidget);
      expect(find.textContaining('回忆层暂时是空的'), findsOneWidget);
    });
  });

  group('memory tier settings', () {
    testWidgets('tier sliders persist as plain int prefs', (tester) async {
      SharedPreferences.setMockInitialValues({});
      container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildShellyTheme(Brightness.light),
            home: const MemorySettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Defaults: recall aging 45 days, archival cap 300 条 (the tier
      // section sits below the fold, so scroll to it first).
      await tester.scrollUntilVisible(
        find.byKey(const Key('recall-age-days-slider')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('记忆整理'), findsOneWidget);
      expect(find.text('45 天'), findsOneWidget);
      // '300 条' also appears in the Hermes 自动记录上限 row, so scope the
      // archival-cap display to the archival-cap slider's card.
      final capDisplay = find.descendant(
        of: find.ancestor(
          of: find.byKey(const Key('archival-cap-slider')),
          matching: find.byType(Column),
        ),
        matching: find.text('300 条'),
      );
      expect(capDisplay, findsOneWidget);

      // Move the recall-aging slider to the right and let the immediate
      // persistence land.
      await tester.ensureVisible(find.byKey(const Key('recall-age-days-slider')));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const Key('recall-age-days-slider')),
        const Offset(60, 0),
      );
      await tester.pumpAndSettle();

      // The archival cap persists the same way on change.
      await tester.drag(
        find.byKey(const Key('archival-cap-slider')),
        const Offset(60, 0),
      );
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      final savedAge = prefs.getInt('shelly.memory.recallAgeDays');
      expect(savedAge, isNotNull);
      expect(savedAge, isNot(45));
      final savedCap = prefs.getInt('shelly.memory.archivalCap');
      expect(savedCap, isNotNull);
      expect(savedCap, isNot(300));
    });

    testWidgets('tier settings reload persisted values on entry', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'shelly.memory.recallAgeDays': 60,
        'shelly.memory.archivalCap': 500,
      });
      container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildShellyTheme(Brightness.light),
            home: const MemorySettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Persisted values reload on entry (the tier section sits below the
      // fold, so scroll to it first).
      await tester.scrollUntilVisible(
        find.byKey(const Key('recall-age-days-slider')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('60 天'), findsOneWidget);
      expect(find.text('500 条'), findsOneWidget);
    });
  });
}
