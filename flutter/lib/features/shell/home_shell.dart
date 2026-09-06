import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/scheduled_tasks.dart';
import '../chat/chat_page.dart';
import '../capabilities/capabilities_page.dart';
import '../history/history_page.dart';
import '../profile/profile_page.dart';
import '../tasks/tasks_page.dart';

/// Currently selected bottom-navigation tab. Global so feature pages
/// (e.g. 历史 → 对话 after resuming) can drive tab switches.
final tabIndexProvider = StateProvider<int>((ref) => 0);

/// Five-tab bottom navigation shell: 对话 / 任务 / 历史 / 能力 / 我的.
/// An [IndexedStack] keeps every tab's scroll and stream state alive while
/// the user switches destinations. The stateful shell also arms the
/// scheduled-task ticker (PHASE 41): started on init, re-ticked on app
/// resume, and re-armed whenever the tasks page changes the schedule.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  static const _pages = <Widget>[
    ChatPage(),
    TasksPage(),
    HistoryPage(),
    CapabilitiesPage(),
    ProfilePage(),
  ];

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell>
    with WidgetsBindingObserver {
  /// Resolved lazily so a slow/failed settings load can never block or
  /// break the shell; cleared on failure so the next trigger retries.
  Future<SchedulerTicker>? _tickerFuture;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _armScheduler();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_resolveTicker().then(
      (ticker) => ticker.dispose(),
      onError: (Object _) {},
    ));
    _tickerFuture = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Coming back to the foreground: re-arm and catch up on any schedule
      // that came due while the app was closed.
      unawaited(_resolveTicker()
          .then((ticker) => ticker.onResume())
          .catchError((Object _) {}));
    }
  }

  void _armScheduler() {
    unawaited(_resolveTicker()
        .then((ticker) => ticker.ensureRunning())
        .catchError((Object _) {}));
  }

  Future<SchedulerTicker> _resolveTicker() {
    return _tickerFuture ??= _createTicker();
  }

  Future<SchedulerTicker> _createTicker() async {
    try {
      final service = await ref.read(schedulerServiceProvider.future);
      return SchedulerTicker(service);
    } catch (error) {
      _tickerFuture = null;
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Creating or enabling a task from the tasks page re-arms the ticker
    // without waiting for the next app resume.
    ref.listen(
      scheduledTasksRevisionProvider,
      (_, _) => _armScheduler(),
    );
    final index = ref.watch(tabIndexProvider);
    return Scaffold(
      body: IndexedStack(index: index, children: HomeShell._pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (value) =>
            ref.read(tabIndexProvider.notifier).state = value,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline_rounded),
            selectedIcon: Icon(Icons.chat_bubble_rounded),
            label: '对话',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_tree_outlined),
            selectedIcon: Icon(Icons.account_tree_rounded),
            label: '任务',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_rounded),
            selectedIcon: Icon(Icons.history_rounded),
            label: '历史',
          ),
          NavigationDestination(
            icon: Icon(Icons.bolt_outlined),
            selectedIcon: Icon(Icons.bolt_rounded),
            label: '能力',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded),
            label: '我的',
          ),
        ],
      ),
    );
  }
}
