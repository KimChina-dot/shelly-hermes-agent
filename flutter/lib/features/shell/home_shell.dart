import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
/// the user switches destinations.
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  static const _pages = <Widget>[
    ChatPage(),
    TasksPage(),
    HistoryPage(),
    CapabilitiesPage(),
    ProfilePage(),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(tabIndexProvider);
    return Scaffold(
      body: IndexedStack(index: index, children: _pages),
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
