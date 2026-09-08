import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'design/theme.dart';
import 'features/shell/home_shell.dart';

/// App-wide theme mode controller. Follows the system by default; the
/// profile page's 外观 row flips this in stage 4.
final themeModeProvider = StateProvider<ThemeMode>((ref) {
  // Web dev harness: ?theme=dark|light pins the mode so browser-based
  // verification tooling can audit each theme deterministically.
  if (kIsWeb) {
    final t = Uri.base.queryParameters['theme'];
    if (t == 'dark') return ThemeMode.dark;
    if (t == 'light') return ThemeMode.light;
  }
  return ThemeMode.system;
});

class ShellyApp extends ConsumerWidget {
  const ShellyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'Shelly Hermes',
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: buildShellyTheme(Brightness.light),
      darkTheme: buildShellyTheme(Brightness.dark),
      home: const HomeShell(),
    );
  }
}
