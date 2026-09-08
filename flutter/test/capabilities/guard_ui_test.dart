import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelly_hermes/app.dart';
import 'package:shelly_hermes/core/mcp/mcp_client.dart';
import 'package:shelly_hermes/core/mcp/mcp_guard.dart';
import 'package:shelly_hermes/state/settings_store.dart';

/// Guard-verdict UI (PHASE 48): the MCP 连接器 section surfaces ledger
/// reports whose tool catalogs drifted from the approved fingerprint, with
/// per-server and bulk re-trust actions that persist the current fingerprint.
///
/// The ledger is in-memory and normally seeded by chat_session before MCP
/// discovery; these tests drive it directly to cover the card's rendering
/// and its persistence side effects.
void main() {
  const toolsA = <Map<String, dynamic>>[
    {'name': 'search_repo', 'description': '搜索仓库内容'},
    {'name': 'clone_repo', 'description': '克隆仓库到工作区'},
  ];
  const toolsB = <Map<String, dynamic>>[
    {'name': 'run_build', 'description': '运行构建脚本'},
  ];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    McpGuardLedger.reset();
  });

  tearDown(McpGuardLedger.reset);

  /// Pumps the real app shell on the capabilities tab with [servers]
  /// pre-registered in the settings store (same override-free pattern as
  /// the existing capability tests in widget_test.dart).
  Future<SettingsStore> pumpCapabilities(
    WidgetTester tester, {
    List<McpServerConfig> servers = const [],
  }) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = await container.read(settingsStoreProvider.future);
    if (servers.isNotEmpty) {
      await store.saveMcpServers(servers);
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const ShellyApp()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('能力'));
    await tester.pumpAndSettle();
    return store;
  }

  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    // scrollUntilVisible stops as soon as the element is built, which can
    // leave it inside the cache extent below the viewport; reveal it fully
    // so taps land on the widget.
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('warning card lists drifted server with its verdict summary', (
    tester,
  ) async {
    // Approved an old catalog; a fresh discovery of toolsA flags the drift.
    McpGuardLedger.seedApproved({'srv-a': 'stale-fingerprint'});
    final report = McpGuardLedger.record('srv-a', toolsA);
    expect(report.verdict, GuardVerdict.changed);

    await pumpCapabilities(
      tester,
      servers: const [
        McpServerConfig(id: 'srv-a', name: 'github', url: 'https://example.com/mcp'),
      ],
    );
    await scrollTo(tester, find.text('MCP 工具目录已变更'));

    expect(find.text('MCP 工具目录已变更'), findsOneWidget);
    expect(find.text('srv-a'), findsOneWidget);
    expect(find.textContaining('疑似 rug pull'), findsOneWidget);
    expect(find.text('重新信任'), findsOneWidget);
    expect(find.text('全部重新信任'), findsOneWidget);
  });

  testWidgets('重新信任 persists the current catalog fingerprint and clears the card', (
    tester,
  ) async {
    McpGuardLedger.seedApproved({'srv-a': 'stale-fingerprint'});
    final report = McpGuardLedger.record('srv-a', toolsA);

    final store = await pumpCapabilities(
      tester,
      servers: const [
        McpServerConfig(id: 'srv-a', name: 'github', url: 'https://example.com/mcp'),
      ],
    );
    await scrollTo(tester, find.text('重新信任'));
    await tester.tap(find.text('重新信任'));
    await tester.pumpAndSettle();

    // The persisted fingerprint is the one the verdict was computed against.
    expect(store.loadMcpToolFingerprints()['srv-a'], report.fingerprint);
    expect(store.loadMcpToolFingerprints()['srv-a'], McpGuard.fingerprint(toolsA));
    // The ledger mirrors the approval, so the card drops the server.
    expect(McpGuardLedger.approvedFor('srv-a'), report.fingerprint);
    expect(find.text('MCP 工具目录已变更'), findsNothing);
  });

  testWidgets('全部重新信任 persists every pending fingerprint', (tester) async {
    McpGuardLedger.seedApproved({'srv-a': 'old-a', 'srv-b': 'old-b'});
    final reportA = McpGuardLedger.record('srv-a', toolsA);
    final reportB = McpGuardLedger.record('srv-b', toolsB);

    final store = await pumpCapabilities(
      tester,
      servers: const [
        McpServerConfig(id: 'srv-a', name: 'github', url: 'https://example.com/mcp'),
        McpServerConfig(id: 'srv-b', name: 'gitlab', url: 'https://example.com/x/mcp'),
      ],
    );
    await scrollTo(tester, find.text('全部重新信任'));
    await tester.tap(find.text('全部重新信任'));
    await tester.pumpAndSettle();

    expect(store.loadMcpToolFingerprints()['srv-a'], reportA.fingerprint);
    expect(store.loadMcpToolFingerprints()['srv-b'], reportB.fingerprint);
    expect(find.text('MCP 工具目录已变更'), findsNothing);
  });

  testWidgets('clean ledger renders no guard card', (tester) async {
    await pumpCapabilities(
      tester,
      servers: const [
        McpServerConfig(id: 'srv-a', name: 'github', url: 'https://example.com/mcp'),
      ],
    );
    await scrollTo(tester, find.text('MCP 连接器'));

    expect(find.text('MCP 工具目录已变更'), findsNothing);
    expect(find.text('重新信任'), findsNothing);
    expect(find.text('全部重新信任'), findsNothing);
  });

  testWidgets('unchanged verdict renders no guard card', (tester) async {
    // Discovery of the same catalog as the approved fingerprint → unchanged,
    // which never requires re-approval.
    McpGuardLedger.seedApproved({'srv-a': McpGuard.fingerprint(toolsA)});
    McpGuardLedger.record('srv-a', toolsA);
    expect(McpGuardLedger.hasPendingReapproval, isFalse);

    await pumpCapabilities(
      tester,
      servers: const [
        McpServerConfig(id: 'srv-a', name: 'github', url: 'https://example.com/mcp'),
      ],
    );
    await scrollTo(tester, find.text('MCP 连接器'));

    expect(find.text('MCP 工具目录已变更'), findsNothing);
    expect(find.text('重新信任'), findsNothing);
  });
}
